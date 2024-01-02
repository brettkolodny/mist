import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/io
import gleam/result
import mist/internal/buffer.{type Buffer}
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Connection, Initial,
}
import mist/internal/http2.{type HpackContext, type Http2Settings, Http2Settings}
import mist/internal/http2/frame.{
  type Frame, type StreamIdentifier, Complete, Settings,
}
import mist/internal/http2/stream

pub type Message {
  Send(identifier: StreamIdentifier(Frame), resp: Response(ResponseData))
}

pub type State {
  State(
    frame_buffer: Buffer,
    hpack_context: HpackContext,
    settings: Http2Settings,
    self: Subject(Message),
  )
}

pub fn with_hpack_context(state: State, context: HpackContext) -> State {
  State(..state, hpack_context: context)
}

pub fn append_data(state: State, data: BitArray) -> State {
  State(..state, frame_buffer: buffer.append(state.frame_buffer, data))
}

pub fn upgrade(
  data: BitArray,
  conn: Connection,
  self: Subject(Message),
) -> Result(State, process.ExitReason) {
  let initial_settings = http2.default_settings()
  let settings_frame =
    frame.Settings(ack: False, settings: [
      frame.HeaderTableSize(initial_settings.header_table_size),
      frame.ServerPush(initial_settings.server_push),
      frame.MaxConcurrentStreams(initial_settings.max_concurrent_streams),
      frame.InitialWindowSize(initial_settings.initial_window_size),
      frame.MaxFrameSize(initial_settings.max_frame_size),
    ])
  let assert Ok(_nil) =
    settings_frame
    |> frame.encode
    |> bytes_builder.from_bit_array
    |> conn.transport.send(conn.socket, _)

  frame.decode(data)
  |> result.map_error(fn(_err) { process.Abnormal("Missing first frame") })
  |> result.then(fn(pair) {
    let assert #(frame, rest) = pair
    case frame {
      Settings(settings: settings, ..) -> {
        let http2_settings = http2.update_settings(initial_settings, settings)
        Ok(State(
          frame_buffer: buffer.new(rest),
          settings: http2_settings,
          hpack_context: http2.hpack_new_context(
            http2_settings.header_table_size,
          ),
          self: self,
        ))
      }
      _ -> {
        let assert Ok(_) = conn.transport.close(conn.socket)
        Error(process.Abnormal("SETTINGS frame must be sent first"))
      }
    }
  })
}

pub fn call(
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, process.ExitReason) {
  case frame.decode(state.frame_buffer.data) {
    Ok(#(frame, rest)) -> {
      io.println("frame:  " <> erlang.format(frame))
      io.println("rest:  " <> erlang.format(rest))
      let new_state = State(..state, frame_buffer: buffer.new(rest))
      case handle_frame(frame, new_state, conn, handler) {
        Ok(updated) -> call(updated, conn, handler)
        Error(reason) -> Error(reason)
      }
    }
    Error(frame.NoError) -> Ok(state)
    Error(_connection_error) -> {
      // TODO:
      //  - send GOAWAY with last good stream ID
      //  - close the connection
      Ok(state)
    }
  }
}

import gleam/erlang

fn handle_frame(
  frame: Frame,
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, process.ExitReason) {
  case frame {
    frame.WindowUpdate(amount, identifier) -> {
      case frame.get_stream_identifier(identifier) {
        0 -> {
          io.println("setting window size!")
          Ok(
            State(
              ..state,
              settings: Http2Settings(
                ..state.settings,
                initial_window_size: amount,
              ),
              hpack_context: state.hpack_context,
            ),
          )
        }
        _n -> {
          todo
        }
      }
    }
    frame.Header(Complete(data), end_stream, identifier, _priority) -> {
      // TODO:  will this be the end headers?  i guess we should wait to
      // receive all of them before starting the stream.  is that how it
      // works?
      let conn =
        Connection(
          body: Initial(<<>>),
          socket: conn.socket,
          transport: conn.transport,
          client_ip: conn.client_ip,
        )
      io.println("we got some headers:  " <> erlang.format(data))
      let assert Ok(new_stream) =
        stream.new(
          identifier,
          state.settings.initial_window_size,
          handler,
          conn,
          fn(resp) { process.send(state.self, Send(identifier, resp)) },
        )
      let assert Ok(#(headers, context)) =
        http2.hpack_decode(state.hpack_context, data)
      process.send(new_stream, stream.Headers(headers, end_stream))
      Ok(State(..state, hpack_context: context))
    }
    frame.Priority(..) -> {
      Ok(state)
    }
    frame.Settings(ack: True, ..) -> {
      let resp =
        frame.Settings(ack: True, settings: [])
        |> frame.encode
      conn.transport.send(conn.socket, bytes_builder.from_bit_array(resp))
      |> result.replace(state)
      |> result.replace_error(process.Abnormal(
        "Failed to respond to settings ACK",
      ))
    }
    frame.GoAway(..) -> {
      io.println("byeeee~~")
      Error(process.Normal)
    }
    // TODO:  obviously fill these out
    _ -> Ok(state)
  }
}
