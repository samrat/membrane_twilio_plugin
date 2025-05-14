Application.put_env(:phoenix, :json_library, Jason)

Application.put_env(:sample, SamplePhoenix.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 5001],
  server: true,
  secret_key_base: String.duplicate("a", 64)
)

Mix.install([
  {:plug_cowboy, "~> 2.5"},
  {:jason, "~> 1.0"},
  {:phoenix, "~> 1.7.0"},
  {:membrane_twilio_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true}
])

defmodule SamplePhoenix.SampleController do
  use Phoenix.Controller

  def index(conn, _) do
    send_resp(conn, 200, "Hello, World!")
  end
end

defmodule Router do
  use Phoenix.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/", SamplePhoenix do
    pipe_through(:browser)

    get("/", SampleController, :index)

    # Prevent a horrible error because ErrorView is missing
    get("/favicon.ico", SampleController, :index)
  end
end

defmodule SamplePhoenix.TwilioSocket do
  @behaviour Phoenix.Socket.Transport

  require Logger

  def child_spec(_opts) do
    # No additional processes needed
    :ignore
  end

  def connect(state) do
    Logger.info("Connection accepted")
    {:ok, state}
  end

  def init(state) do
    {:ok, state}
  end

  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "connected"}} ->
        Logger.info("Twilio connected")
        {:ok, state}

      {:ok, %{"event" => "start", "streamSid" => stream_sid} = data} ->
        Logger.info("Start Message received: #{inspect(data)}")
        # Start the pipeline when we get the start message with stream_sid
        {:ok, supervisor_pid, pipeline_pid} =
          Membrane.Pipeline.start_link(SamplePhoenix.TwilioPipeline, %{
            stream_sid: stream_sid,
            socket_pid: self()
          })

        state =
          state
          |> Map.put(:pipeline_pid, pipeline_pid)
          |> Map.put(:supervisor_pid, supervisor_pid)

        {:ok, state}

      {:ok, _data} ->
        # Forward other messages to pipeline if it exists
        if state[:pipeline_pid] do
          send(state.pipeline_pid, {:twilio_incoming_data, text})
        end

        {:ok, state}

      {:error, error} ->
        Logger.error("Failed to decode message: #{inspect(error)}")
        {:ok, state}
    end
  end

  def handle_info({:socket_push, encoded}, state) do
    {:reply, :ok, {:text, encoded}, state}
  end

  def terminate(_reason, state) do
    # Cleanup pipeline
    if state[:pipeline_pid] do
      Membrane.Pipeline.terminate(state.pipeline_pid)
    end

    :ok
  end
end

defmodule SamplePhoenix.TwilioPipeline do
  use Membrane.Pipeline
  alias Membrane.FFmpeg.SWResample.Converter

  require Logger

  @impl true
  def handle_init(_ctx, options) do
    structure = [
      child(:twilio, %Membrane.Twilio.Endpoint{
        stream_sid: options.stream_sid
      })
      # NOTE: Without the debug filter, Membrane complains that
      # `:twilio` is connected to itself.
      # In a real world scenario(where you're not just echoing back the data),
      # you can remove this filter.
      |> child(:filter, %Membrane.Debug.Filter{
        handle_buffer: &IO.inspect(&1, label: "buffer"),
        handle_stream_format: &IO.inspect(&1, label: "stream format")
      })
      |> get_child(:twilio)
    ]

    {[spec: structure], %{socket_pid: options.socket_pid, playing: false}}
  end

  @impl true
  def handle_child_notification({:twilio_message, message}, :twilio, _ctx, state) do
    # Send the message through Phoenix.Socket.Transport
    encoded = Jason.encode!(message) |> dbg()
    send(state.socket_pid, {:socket_push, encoded})
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    Membrane.Logger.info("Playing")

    # Give the pipeline some time to start playing
    Process.send_after(self(), :set_playing, 1000)
    {[], state}
  end

  @impl true
  def handle_info({:twilio_incoming_data, data}, ctx, state) do
    # Forward incoming data to the endpoint
    if state.playing do
      actions = [notify_child: {:twilio, {:incoming_data, data}}]
      {actions, state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_info(:set_playing, _ctx, state) do
    {[], %{state | playing: true}}
  end
end

defmodule SamplePhoenix.Endpoint do
  use Phoenix.Endpoint, otp_app: :sample

  socket("/media", SamplePhoenix.TwilioSocket,
    websocket: true,
    longpoll: false
  )

  plug(Router)
end

{:ok, _} = Supervisor.start_link([SamplePhoenix.Endpoint], strategy: :one_for_one)
Process.sleep(:infinity)
