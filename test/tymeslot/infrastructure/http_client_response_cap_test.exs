defmodule Tymeslot.Infrastructure.HTTPClientResponseCapTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.ResponseTooLargeError

  describe "response byte budget" do
    setup do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 200, String.duplicate("a", 4096))
      end)

      :ok
    end

    test "returns an ordinary binary body when the response fits" do
      assert {:ok, %Req.Response{status: 200, body: body}} =
               HTTPClient.get("http://localhost/small", [], max_response_bytes: 8192)

      assert body == String.duplicate("a", 4096)
    end

    test "an empty body still arrives as a binary" do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 204, "") end)

      assert {:ok, %Req.Response{status: 204, body: ""}} = HTTPClient.get("http://localhost/none")
    end

    test "refuses a response that exceeds the budget" do
      assert {:error, %ResponseTooLargeError{max_bytes: 1024} = error} =
               HTTPClient.get("http://localhost/big", [], max_response_bytes: 1024)

      assert Exception.message(error) =~ "exceeded the 1024 byte limit"
    end

    test "the budget applies to every method, not just GET" do
      assert {:error, %ResponseTooLargeError{}} =
               HTTPClient.report("http://localhost/cal", "<query/>", [], max_response_bytes: 100)
    end

    test "a HEAD response, which has no body at all, still succeeds" do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 200, "") end)

      assert {:ok, %Req.Response{status: 200, body: ""}} =
               HTTPClient.head("http://localhost/here")
    end

    test "a followed redirect returns only the final response body" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          "/moved" ->
            conn
            |> Conn.put_resp_header("location", "http://localhost/final")
            |> Conn.send_resp(302, "redirect body that must not leak into the result")

          "/final" ->
            Conn.send_resp(conn, 200, "final body")
        end
      end)

      assert {:ok, %Req.Response{status: 200, body: "final body"}} =
               HTTPClient.get("http://localhost/moved")
    end

    test "leaves body handling alone when the caller supplies its own :into" do
      assert {:ok, %Req.Response{status: 200, body: body}} =
               HTTPClient.get("http://localhost/streamed", [], into: [])

      assert body == [String.duplicate("a", 4096)]
    end
  end

  describe "streaming abort" do
    @chunk_size 64 * 1024
    @chunk_count 400

    setup do
      # Bypass the Req test plug so the request travels over a real socket and
      # the body genuinely arrives in separate chunks.
      previous = Application.get_env(:tymeslot, :req_test_plug)
      Application.delete_env(:tymeslot, :req_test_plug)
      on_exit(fn -> Application.put_env(:tymeslot, :req_test_plug, previous) end)

      test_pid = self()

      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.ChunkedPlug, %{test_pid: test_pid, chunks: @chunk_count}},
          scheme: :http,
          port: 0,
          startup_log: false
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      %{port: port}
    end

    test "aborts the transfer instead of buffering the whole body", %{port: port} do
      assert {:error, %ResponseTooLargeError{}} =
               HTTPClient.get("http://127.0.0.1:#{port}/stream", [],
                 max_response_bytes: @chunk_size
               )

      assert_receive {:chunks_written, written}, 5_000

      # The server is cut off once the client halts. Socket buffers absorb some
      # of what follows, but nowhere near the full 25 MB the server offered.
      assert written < @chunk_count
    end
  end

  defmodule ChunkedPlug do
    @moduledoc false

    @behaviour Plug

    alias Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{test_pid: test_pid, chunks: chunks}) do
      conn = Conn.send_chunked(conn, 200)
      payload = String.duplicate("a", 64 * 1024)

      {conn, written} =
        Enum.reduce_while(1..chunks, {conn, 0}, fn _index, {conn, written} ->
          case Conn.chunk(conn, payload) do
            {:ok, conn} -> {:cont, {conn, written + 1}}
            {:error, _reason} -> {:halt, {conn, written}}
          end
        end)

      send(test_pid, {:chunks_written, written})
      conn
    end
  end
end
