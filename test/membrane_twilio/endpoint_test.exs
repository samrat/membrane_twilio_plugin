defmodule Membrane.Twilio.EndpointTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.Testing
  alias Membrane.Twilio.Endpoint

  defmodule TestSink do
    use Membrane.Sink

    def_input_pad(:input,
      accepted_format: %Membrane.G711{encoding: :PCMU}
    )

    @impl true
    def handle_init(_ctx, _opts) do
      {[], %{messages: []}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[notify_parent: :playing], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[notify_parent: {:buffer_received, buffer}], state}
    end
  end

  defmodule TestSource do
    use Membrane.Source

    def_output_pad(:output,
      accepted_format: %Membrane.G711{encoding: :PCMU},
      flow_control: :manual
    )

    @impl true
    def handle_init(_ctx, _opts) do
      {[], %{stream_format: %Membrane.G711{encoding: :PCMU}}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[stream_format: {:output, state.stream_format}, notify_parent: :playing], state}
    end

    @impl true
    def handle_parent_notification(:send_buffer, _ctx, state) do
      # Some sample uLaw data (20ms of silence at 8kHz)
      payload = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>> <> String.duplicate(<<0xFF>>, 155)
      buffer = %Membrane.Buffer{payload: payload}
      {[buffer: {:output, buffer}], state}
    end

    @impl true
    def handle_demand(:output, _size, _unit, _ctx, state) do
      {[], state}
    end
  end

  describe "Endpoint receiving data" do
    test "handles incoming Twilio media message" do
      stream_sid = "ABCDEFGHIJKLMNOP"

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            # Add a dummy source to satisfy the input pad connection requirement
            child(:source, TestSource)
            |> child(:endpoint, %Endpoint{stream_sid: stream_sid})
            |> child(:sink, TestSink)
          ]
        )

      # Ensure pipeline is playing
      assert_pipeline_notified(pipeline, :sink, :playing, 1000)

      # Prepare a sample uLaw payload - 5 bytes of a uLaw-encoded audio
      ulaws = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
      base64_payload = Base.encode64(ulaws)

      # Construct a Twilio message with the payload
      twilio_message =
        Jason.encode!(%{
          "event" => "media",
          "media" => %{"payload" => base64_payload}
        })

      # Send the message to the endpoint
      Testing.Pipeline.execute_actions(pipeline,
        notify_child: {:endpoint, {:incoming_data, twilio_message}}
      )

      # Wait for the buffer to be received by the sink
      assert_pipeline_notified(
        pipeline,
        :sink,
        {:buffer_received, %Membrane.Buffer{payload: ^ulaws}},
        1000
      )

      Testing.Pipeline.terminate(pipeline)
    end

    test "handles non-media Twilio messages without error" do
      stream_sid = "ABCDEFGHIJKLMNOP"

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, TestSource)
            |> child(:endpoint, %Endpoint{stream_sid: stream_sid})
            |> child(:sink, TestSink)
          ]
        )

      # Ensure pipeline is playing
      assert_pipeline_notified(pipeline, :sink, :playing, 1000)

      # Construct a Twilio mark message
      twilio_message =
        Jason.encode!(%{
          "event" => "mark",
          "streamSid" => stream_sid,
          "name" => "test_mark"
        })

      # Send the message to the endpoint
      Testing.Pipeline.execute_actions(pipeline,
        notify_child: {:endpoint, {:incoming_data, twilio_message}}
      )

      # No errors should occur
      refute_pipeline_notified(pipeline, :endpoint, {:error, _}, 1000)

      Testing.Pipeline.terminate(pipeline)
    end

    test "handles invalid JSON data without crashing" do
      stream_sid = "ABCDEFGHIJKLMNOP"

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, TestSource)
            |> child(:endpoint, %Endpoint{stream_sid: stream_sid})
            |> child(:sink, TestSink)
          ]
        )

      # Ensure pipeline is playing
      assert_pipeline_notified(pipeline, :sink, :playing, 1000)

      # Send invalid JSON
      invalid_json = "this is not valid json"

      # Send the message to the endpoint
      Testing.Pipeline.execute_actions(pipeline,
        notify_child: {:endpoint, {:incoming_data, invalid_json}}
      )

      # No errors should propagate and terminate the pipeline
      refute_pipeline_notified(pipeline, :endpoint, {:error, _}, 1000)

      Testing.Pipeline.terminate(pipeline)
    end
  end

  describe "Endpoint sending data" do
    test "sends Twilio message with audio data" do
      stream_sid = "ABCDEFGHIJKLMNOP"

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, TestSource)
            |> child(:endpoint, %Endpoint{stream_sid: stream_sid})
            |> child(:sink, TestSink)
          ]
        )

      # Ensure pipeline is playing
      assert_pipeline_notified(pipeline, :source, :playing, 1000)

      # Send a buffer from the source
      Testing.Pipeline.execute_actions(pipeline,
        notify_child: {:source, :send_buffer}
      )

      # Wait for the notification from the endpoint with the Twilio message
      assert_pipeline_notified(
        pipeline,
        :endpoint,
        {:twilio_message,
         %{
           event: "media",
           streamSid: ^stream_sid,
           media: %{payload: _}
         }},
        1000
      )

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
