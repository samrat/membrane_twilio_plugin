defmodule Membrane.Twilio.Endpoint do
  use Membrane.Endpoint

  require Logger

  @stream_format %Membrane.G711{encoding: :PCMU}

  def_input_pad(:input,
    accepted_format: @stream_format
  )

  def_output_pad(:output,
    flow_control: :push,
    accepted_format: @stream_format
  )

  def_options(
    stream_sid: [
      spec: String.t(),
      description: "Twilio stream SID"
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    state = %{
      stream_sid: options.stream_sid
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    Membrane.Logger.info("Playing")
    {[stream_format: {:output, @stream_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # Check if the buffer payload is entirely zeros (silence for s16le)
    is_silent = buffer.payload == <<0::size(byte_size(buffer.payload) * 8)>>

    if is_silent do
      # Audio is silent, do not send a message
      Logger.debug("Received silent audio buffer, skipping Twilio message.")
      {[], state}
    else
      # Audio is not silent

      # Convert audio data to base64
      payload = Base.encode64(buffer.payload)

      message = %{
        event: "media",
        streamSid: state.stream_sid,
        media: %{payload: payload}
      }

      # Notify parent (pipeline) about the message to send
      actions = [notify_parent: {:twilio_message, message}]

      {actions, state}
    end
  end

  @impl true
  def handle_parent_notification({:incoming_data, text}, _ctx, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "media", "media" => %{"payload" => payload}}} ->
        with {:ok, ulaw_data} <- Base.decode64(payload) do
          buffer = %Membrane.Buffer{payload: ulaw_data}
          actions = [buffer: {:output, buffer}]
          {actions, state}
        else
          error ->
            Logger.error("Failed to decode base64 payload: #{inspect(error)}")
            {[], state}
        end

      {:ok, data} ->
        Logger.info("Received Twilio event: #{inspect(data)}")
        {[], state}

      {:error, _} ->
        Logger.error("Failed to decode message: #{text}")
        {[], state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    # Send stream close message
    message =
      Jason.encode!(%{
        "event" => "closed",
        "streamSid" => state.stream_sid
      })

    Logger.debug("Sending close message: #{message}")

    {[], state}
  end
end
