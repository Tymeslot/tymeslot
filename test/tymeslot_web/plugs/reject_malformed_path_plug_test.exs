defmodule TymeslotWeb.Plugs.RejectMalformedPathPlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :infrastructure

  alias TymeslotWeb.Plugs.RejectMalformedPathPlug

  defp run(path), do: :get |> build_conn(path) |> RejectMalformedPathPlug.call([])

  describe "rejected paths" do
    test "a segment that decodes to invalid UTF-8" do
      conn = run("/%c0")

      assert conn.halted
      assert conn.status == 400
    end

    test "invalid UTF-8 in a later segment" do
      assert run("/alice/%ff%fe").status == 400
    end

    test "a segment that decodes to a NUL byte" do
      assert run("/alice/meeting/%00/cancel").status == 400
    end
  end

  describe "paths left alone" do
    test "the root path" do
      refute run("/").halted
    end

    test "a percent-encoded multibyte character" do
      refute run("/caf%C3%A9").halted
    end

    test "a plain username and slug" do
      refute run("/alice/intro-call").halted
    end
  end

  describe "through the endpoint" do
    test "every username route answers 400 without reaching the database", %{conn: conn} do
      for path <- [
            "/%c0",
            "/%c0/intro-call",
            "/%c0/meeting/abc/cancel",
            "/%c0/meeting/abc/calendar.ics",
            "/%c0/poll/token",
            "/alice/meeting/%00/cancel"
          ] do
        assert conn |> get(path) |> response(400) == "Bad Request", path
      end
    end
  end
end
