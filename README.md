# Membrane Twilio Plugin

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `membrane_twilio_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_twilio_plugin, "~> 0.1.0"}
  ]
end
```

## Usage (TODO: elaborate)

- Create your Membrane pipeline using `Membrane.Twilio.Endpoint`
- Add WebSocket route that forwards data from Twilio to the pipeline, and vice-versa
- (When developing locally), you'll need to use `cloudflared` or `ngrok` to expose your local server.
- Set up TwiML bin:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Response>
    <Connect>
        <Stream url="wss://YOUR-CLOUDFLARED-PROVIDED-URL.trycloudflare.com/media/websocket" />
     </Connect>
</Response>
```

- Hook up your number to the TwiML bin(TODO: add screenshots)
