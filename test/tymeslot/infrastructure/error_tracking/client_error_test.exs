defmodule Tymeslot.Infrastructure.ErrorTracking.ClientErrorTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  defmodule MisconfiguredError do
    defexception message: "bad status", plug_status: :not_a_status
  end

  describe "client_error?/1" do
    test "is true for an exception rendered as a 4xx" do
      assert ClientError.client_error?(%Plug.Parsers.ParseError{exception: nil})
      assert ClientError.client_error?(%Phoenix.Router.MalformedURIError{message: "bad"})
      assert ClientError.client_error?(%Plug.Conn.InvalidQueryError{message: "bad"})
    end

    test "is false for an exception rendered as a 5xx" do
      refute ClientError.client_error?(%RuntimeError{message: "boom"})
    end

    test "is false, with a warning, when the status cannot be resolved" do
      log = capture_log(fn -> refute ClientError.client_error?(%MisconfiguredError{}) end)

      assert log =~ "Could not tell whether an exception is a client error"
    end

    test "is false for a value that is not an exception" do
      refute ClientError.client_error?(:not_found)
    end
  end

  describe "client_error_kind?/1" do
    test "resolves the exception module from its name" do
      assert ClientError.client_error_kind?("Elixir.Plug.BadRequestError")
      refute ClientError.client_error_kind?("Elixir.RuntimeError")
    end

    test "is false for a module that is not an exception" do
      refute ClientError.client_error_kind?("Elixir.Enum")
    end

    test "is false for a name that is not an existing atom" do
      log =
        capture_log(fn ->
          refute ClientError.client_error_kind?("Elixir.Tymeslot.NoSuchModuleEverDefined")
        end)

      assert log =~ "Could not tell whether an exception is a client error"
    end
  end
end
