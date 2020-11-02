defmodule OsCmd do
  use GenServer
  alias OsCmd.Faker

  defmodule Error do
    defexception [:message, :exit_status]
  end

  def start_link(command) when is_binary(command), do: start_link({command, []})

  def start_link({command, opts}) do
    opts = normalize_opts(opts)
    GenServer.start_link(__MODULE__, {command, opts}, Keyword.take(opts, [:name]))
  end

  def stop(server, timeout \\ :infinity) do
    pid = GenServer.whereis(server)
    mref = Process.monitor(pid)
    GenServer.cast(pid, :stop)

    receive do
      {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
    after
      timeout -> exit(:timeout)
    end
  end

  def events(server) do
    Stream.resource(
      fn -> Process.monitor(server) end,
      fn
        nil ->
          {:halt, nil}

        mref ->
          receive do
            {^server, {:stopped, _} = stopped} ->
              Process.demonitor(mref, [:flush])
              {[stopped], nil}

            {^server, message} ->
              {[message], mref}

            {:DOWN, ^mref, :process, ^server, reason} ->
              {[{:terminated, reason}], nil}
          end
      end,
      fn
        nil -> :ok
        mref -> Process.demonitor(mref, [:flush])
      end
    )
  end

  def run(cmd, opts \\ []) do
    start_arg = {cmd, [notify: self()] ++ opts}

    start_fun =
      case Keyword.fetch(opts, :start) do
        :error -> fn -> start_link(start_arg) end
        {:ok, fun} -> fn -> fun.({__MODULE__, start_arg}) end
      end

    with {:ok, pid} <- start_fun.() do
      try do
        pid
        |> events()
        |> Enum.reduce(
          %{output: [], exit_status: nil},
          fn
            {:output, output}, acc -> update_in(acc.output, &[&1, output])
            {:stopped, exit_status}, acc -> %{acc | exit_status: exit_status}
            {:terminated, reason}, acc -> %{acc | exit_status: reason}
          end
        )
        |> case do
          %{exit_status: 0} = result -> {:ok, to_string(result.output)}
          result -> {:error, result.exit_status, to_string(result.output)}
        end
      after
        stop(pid)
      end
    end
  end

  def allow(pid), do: Faker.allow(pid)
  def expect(fun), do: Faker.expect(fun)
  def stub(fun), do: Faker.stub(fun)

  @impl GenServer
  def init({cmd, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, timeout} <- Keyword.fetch(opts, :timeout),
         do: Process.send_after(self(), :timeout, timeout)

    starter =
      case Faker.fetch() do
        {:ok, pid} ->
          Mox.allow(Faker.Port, pid, self())
          Faker.Port

        :error ->
          OsCmd.Port
      end

    case starter.start(cmd, opts) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           handler: Keyword.get(opts, :handler),
           propagate_exit?: Keyword.get(opts, :propagate_exit?, false),
           buffer: ""
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state),
    # Delegating to `handle_continue` because we must invoke a custom handler which can crash, so
    # we need to make sure that the correct state is committed.
    do: {:noreply, %{state | port: nil}, {:continue, {:stop, exit_status}}}

  def handle_info({port, {:data, message}}, %{port: port} = state) do
    state = invoke_handler(state, message)
    {:noreply, state}
  end

  def handle_info(:timeout, state), do: stop_server(state, :timeout)

  @impl GenServer
  def handle_continue({:stop, exit_status}, state) do
    state = invoke_handler(state, {:stopped, exit_status})
    exit_reason = if exit_status == 0, do: :normal, else: {:failed, exit_status}
    stop_server(%{state | port: nil}, exit_reason)
  end

  @impl GenServer
  def handle_cast(:stop, state), do: stop_server(state, :normal)

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, state), do: stop_program(state)

  defp normalize_opts(opts) do
    handler =
      opts
      |> Keyword.get_values(:notify)
      |> Enum.reduce(
        Keyword.get(opts, :handler),
        fn pid, handler ->
          fn message ->
            send(pid, {self(), message})
            handler && handler.(message)
          end
        end
      )

    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn
        {name, nil} -> {to_charlist(name), false}
        {name, value} -> {to_charlist(name), to_charlist(value)}
      end)

    Keyword.merge(opts, handler: handler, env: env)
  end

  defp stop_server(%{propagate_exit?: false} = state, _exit_reason), do: {:stop, :normal, state}
  defp stop_server(state, reason), do: {:stop, reason, state}

  defp invoke_handler(%{handler: nil} = state, _message), do: state

  defp invoke_handler(%{handler: handler} = state, message) do
    message = with message when is_binary(message) <- message, do: :erlang.binary_to_term(message)
    {message, state} = normalize_message(message, state)
    handler.(message)
    state
  end

  defp normalize_message({:output, output}, state) do
    {output, rest} = get_utf8_chars(state.buffer <> output)
    {{:output, to_string(output)}, %{state | buffer: rest}}
  end

  defp normalize_message(message, state), do: {message, state}

  defp get_utf8_chars(<<char::utf8, rest::binary>>) do
    {remaining_bytes, rest} = get_utf8_chars(rest)
    {[char | remaining_bytes], rest}
  end

  defp get_utf8_chars(other), do: {[], other}

  defp stop_program(%{port: port} = state) do
    Port.command(port, "stop")

    Stream.repeatedly(fn ->
      receive do
        {^port, {:data, message}} -> invoke_handler(state, message)
        {^port, {:exit_status, _exit_status}} -> nil
      end
    end)
    |> Enum.find(&is_nil/1)
  end

  defmodule Program do
    @moduledoc false
    @type id :: any

    @callback start(cmd :: String.t() | [String.t()], opts :: Keyword.t()) ::
                {:ok, id} | {:error, reason :: any}
  end
end
