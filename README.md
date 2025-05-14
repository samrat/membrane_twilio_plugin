# Membrane Twilio Plugin

A plugin for the [Membrane Framework](https://membrane.stream) that enables integration with [Twilio Media Streams](https://www.twilio.com/docs/voice/twiml/stream). It allows real-time processing of audio from Twilio phone calls using WebSockets, supporting bidirectional audio communication in G711 μ-law format.

## Installation

```elixir
def deps do
  [
    # Hex package coming soon
    {:membrane_twilio_plugin, github: "samrat/membrane_twilio_plugin"}
  ]
end
```

## Usage

For a complete example, see `examples/echo.exs`, which creates a simple echo service that sends back whatever audio is received from a phone call.

### Step 1: Set up a Phoenix application with WebSocket support

```elixir
# Configure Phoenix
Application.put_env(:phoenix, :json_library, Jason)
Application.put_env(:sample, YourApp.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 5001],
  server: true,
  secret_key_base: String.duplicate("a", 64)
)

# Define your Phoenix endpoint
defmodule YourApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :sample

  socket("/media", YourApp.TwilioSocket,
    websocket: true,
    longpoll: false
  )

  # Your additional plugs here
end
```

### Step 2: Implement a WebSocket handler for Twilio Media Streams

```elixir
defmodule YourApp.TwilioSocket do
  @behaviour Phoenix.Socket.Transport
  require Logger

  def child_spec(_opts), do: :ignore

  def connect(state) do
    Logger.info("Connection accepted")
    {:ok, state}
  end

  def init(state), do: {:ok, state}

  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "connected"}} ->
        Logger.info("Twilio connected")
        {:ok, state}

      {:ok, %{"event" => "start", "streamSid" => stream_sid} = data} ->
        Logger.info("Start Message received: #{inspect(data)}")
        # Start the pipeline when we get the start message
        {:ok, supervisor_pid, pipeline_pid} =
          Membrane.Pipeline.start_link(YourApp.TwilioPipeline, %{
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
```

### Step 3: Create a Membrane Pipeline with the Twilio Endpoint

```elixir
defmodule YourApp.TwilioPipeline do
  use Membrane.Pipeline
  require Logger

  @impl true
  def handle_init(_ctx, options) do
    # Pipeline structure that connects the Twilio endpoint to your audio processing chain
    structure = [
      child(:twilio, %Membrane.Twilio.Endpoint{
        stream_sid: options.stream_sid
      })
      # Add your audio processing elements here
      # In this basic example, we loop the audio back to the caller
      |> child(:filter, %Membrane.Debug.Filter{})
      |> get_child(:twilio)
    ]

    {[spec: structure], %{socket_pid: options.socket_pid, playing: false}}
  end

  @impl true
  def handle_child_notification({:twilio_message, message}, :twilio, _ctx, state) do
    # Send the message back through the WebSocket
    encoded = Jason.encode!(message)
    send(state.socket_pid, {:socket_push, encoded})
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Give the pipeline some time to initialize
    Process.send_after(self(), :set_playing, 1000)
    {[], state}
  end

  @impl true
  def handle_info({:twilio_incoming_data, data}, _ctx, state) do
    # Forward incoming data to the endpoint
    if state.playing do
      {[notify_child: {:twilio, {:incoming_data, data}}], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_info(:set_playing, _ctx, state) do
    {[], %{state | playing: true}}
  end
end
```

### Step 4: Expose your application to the internet

When testing locally, you'll need to expose your application to the internet so Twilio can connect to it. You can use tools like:

- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-guide/)
- [ngrok](https://ngrok.com/)

Example with cloudflared:
```bash
cloudflared tunnel --url http://localhost:5001
```

### Step 5: Configure Twilio

1. Create a TwiML Bin in your Twilio account with the following content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Response>
    <Connect>
        <Stream url="wss://YOUR-TUNNEL-URL.trycloudflare.com/media/websocket" />
     </Connect>
</Response>
```

2. Assign this TwiML Bin to a Twilio phone number:
   - Go to your Twilio Console
   - Navigate to Phone Numbers > Manage > Active Numbers
   - Select your number and set the Voice Webhook to your TwiML Bin URL

Now when someone calls your Twilio number, the audio will be streamed to your application for processing!

## License
Copyright (c) 2025 [Samrat Man Singh](https://samrat.me)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
