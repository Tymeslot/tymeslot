defmodule Tymeslot.Integrations.Common.ErrorHandlerTest do
  @moduletag :integrations
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Common.ErrorHandler

  describe "normalize_error/1" do
  @moduletag :integrations
    test "normalizes 3-tuple errors" do
      assert {:error, "timeout"} = ErrorHandler.normalize_error({:error, :type, "timeout"})
    end

    test "normalizes 2-tuple errors" do
      assert {:error, "reason"} = ErrorHandler.normalize_error({:error, "reason"})
    end

    test "passes through ok tuples" do
      assert {:ok, :result} = ErrorHandler.normalize_error({:ok, :result})
    end

    test "passes through other values" do
      assert :other = ErrorHandler.normalize_error(:other)
    end
  end

  describe "handle_with_logging/2" do
    test "returns ok for success" do
      assert {:ok, :success} = ErrorHandler.handle_with_logging(fn -> {:ok, :success} end)
    end

    test "logs and returns error for 2-tuple failure" do
      log =
        capture_log(fn ->
          assert {:error, "fail"} =
                   ErrorHandler.handle_with_logging(fn -> {:error, "fail"} end,
                     operation: "op",
                     provider: "prov"
                   )
        end)

      assert log =~ "Integration error during op (prov): fail"
    end

    test "logs and returns normalized error for 3-tuple failure" do
      log =
        capture_log(fn ->
          assert {:error, "timeout"} =
                   ErrorHandler.handle_with_logging(fn -> {:error, :net, "timeout"} end)
        end)

      assert log =~ "Integration error during unknown operation (unknown provider): timeout"
    end

    test "suppresses logging for specified errors" do
      log =
        capture_log(fn ->
          assert {:error, :ignored} =
                   ErrorHandler.handle_with_logging(fn -> {:error, :ignored} end,
                     suppress_errors: [:ignored]
                   )
        end)

      assert log == ""
    end

    test "handles exceptions" do
      log =
        capture_log(fn ->
          assert {:error, "oops"} = ErrorHandler.handle_with_logging(fn -> raise "oops" end)
        end)

      assert log =~ "Integration error during unknown operation (unknown provider): oops"
    end
  end

  describe "handle_integration_error/3" do
    test "translates and logs error" do
      log =
        capture_log(fn ->
          assert {:error, :timeout, translated} =
                   ErrorHandler.handle_integration_error(:timeout, "google")

          assert translated.category == :network
          assert translated.message =~ "Connection timeout"
        end)

      assert log =~ "Integration error"
      assert log =~ "category=network"
    end
  end

  describe "with_error_handling/3" do
    test "handles success" do
      assert {:ok, :res} = ErrorHandler.with_error_handling("google", "op", fn -> {:ok, :res} end)
    end

    test "handles error by translating it" do
      capture_log(fn ->
        assert {:error, :timeout, translated} =
                 ErrorHandler.with_error_handling("google", "op", fn -> {:error, :timeout} end)

        assert translated.category == :network
      end)
    end

    test "handles exceptions by translating them" do
      capture_log(fn ->
        assert {:error, "boom", translated} =
                 ErrorHandler.with_error_handling("google", "op", fn -> raise "boom" end)

        assert translated.category == :unknown
      end)
    end
  end

  describe "handle_database_error/1" do
    test "handles changeset errors" do
      changeset = Changeset.change({%{}, %{name: :string}}, %{name: "test"})
      changeset = Changeset.add_error(changeset, :name, "too short")

      assert {:error, message} = ErrorHandler.handle_database_error({:error, changeset})
      assert message =~ "Database validation failed"
      assert message =~ "name: too short"
    end

    test "handles other database errors" do
      assert {:error, message} = ErrorHandler.handle_database_error({:error, :not_found})
      assert message =~ "Database operation failed: :not_found"
    end

    test "passes through ok result" do
      assert {:ok, :res} = ErrorHandler.handle_database_error({:ok, :res})
    end
  end

  describe "handle_http_error/2" do
    test "handles status >= 400" do
      resp = %{status: 404, body: "Not found"}
      assert {:error, "HTTP 404: Not found"} = ErrorHandler.handle_http_error({:ok, resp})
    end

    test "handles 2xx status" do
      resp = %{status: 200, body: "OK"}
      assert {:ok, ^resp} = ErrorHandler.handle_http_error({:ok, resp})
    end

    test "handles Finch/HTTPoison errors" do
      error = %Finch.Error{reason: :timeout}
      assert {:error, message} = ErrorHandler.handle_http_error({:error, error})
      assert message =~ "HTTP request failed: timeout"
    end

    test "parses google-specific error body" do
      body = %{"error" => %{"message" => "Google error message"}}
      resp = %{status: 401, body: body}

      assert {:error, "HTTP 401: Google error message"} =
               ErrorHandler.handle_http_error({:ok, resp}, :google)
    end

    test "parses microsoft-specific error body" do
      body = %{"error" => %{"message" => "Microsoft error message"}}
      resp = %{status: 403, body: body}

      assert {:error, "HTTP 403: Microsoft error message"} =
               ErrorHandler.handle_http_error({:ok, resp}, :outlook)
    end
  end

  describe "error category mapping for 401 and 403" do
    test "translates 401 to authentication category" do
      capture_log(fn ->
        assert {:error, {:http_error, 401}, translated} =
                 ErrorHandler.handle_integration_error({:http_error, 401}, "google")

        assert translated.category == :authentication
        assert translated.message =~ "Authentication failed"
      end)
    end

    test "translates 403 to permission category" do
      capture_log(fn ->
        assert {:error, {:http_error, 403}, translated} =
                 ErrorHandler.handle_integration_error({:http_error, 403}, "google")

        assert translated.category == :permission
        assert translated.message =~ "Insufficient permissions"
      end)
    end
  end
end
