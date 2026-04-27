defmodule Tymeslot.Mailer.PostmarkProbeTest do
  # async: false — :meck patches the Finch module globally for the duration of
  # each test, which is incompatible with concurrent test execution.
  use ExUnit.Case, async: false
  @moduletag :mailer

  import ExUnit.CaptureLog

  alias Tymeslot.Mailer.PostmarkProbe

  # ---------------------------------------------------------------------------
  # Test config
  # ---------------------------------------------------------------------------

  @valid_config [api_key: "test-api-key-12345"]

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  # The application supervisor starts `Tymeslot.Finch` in test, so
  # `Process.whereis(Tymeslot.Finch)` is already non-nil and `test_api_key/1`
  # reaches `do_test_api_key/1`. We patch `Finch.request/3` via :meck to avoid
  # real network traffic.
  setup do
    unload_if_loaded(Finch)
    :meck.new(Finch, [:passthrough])

    on_exit(fn ->
      unload_if_loaded(Finch)
    end)

    :ok
  end

  defp unload_if_loaded(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end

  # ---------------------------------------------------------------------------
  # HTTP response code branches (Finch started + mocked)
  # ---------------------------------------------------------------------------

  describe "test_api_key/1 — HTTP response branches" do
    test "returns :ok on a 200 response" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:ok, %Finch.Response{status: 200, headers: [], body: "{}"}}
      end)

      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log([level: :info], fn ->
          assert :ok = PostmarkProbe.test_api_key(@valid_config)
        end)

      Logger.configure(level: original_level)

      assert log =~ "Postmark API key validation passed"
    end

    test "returns an error on a 401 Unauthorized response" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:ok, %Finch.Response{status: 401, headers: [], body: ""}}
      end)

      capture_log(fn ->
        assert {:error, message} = PostmarkProbe.test_api_key(@valid_config)
        assert message =~ "401"
        assert message =~ "Invalid Postmark API key"
      end)
    end

    test "returns an error on a 422 Unprocessable Entity response" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:ok, %Finch.Response{status: 422, headers: [], body: ~s({"Message":"bad key"})}}
      end)

      capture_log(fn ->
        assert {:error, message} = PostmarkProbe.test_api_key(@valid_config)
        assert message =~ "422"
      end)
    end

    test "returns an error on an unexpected status code" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:ok, %Finch.Response{status: 500, headers: [], body: "Internal Server Error"}}
      end)

      capture_log(fn ->
        assert {:error, message} = PostmarkProbe.test_api_key(@valid_config)
        assert message =~ "500"
        assert message =~ "unexpected status"
      end)
    end

    test "returns an error on a network timeout" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:error, %{reason: :timeout}}
      end)

      capture_log(fn ->
        assert {:error, message} = PostmarkProbe.test_api_key(@valid_config)
        assert message =~ "Timeout"
        assert message =~ "Postmark"
      end)
    end

    test "returns an error on a generic network error" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      capture_log(fn ->
        assert {:error, message} = PostmarkProbe.test_api_key(@valid_config)
        assert message =~ "Cannot connect to Postmark API"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Request construction
  # ---------------------------------------------------------------------------

  describe "test_api_key/1 — request construction" do
    test "sends the API key in the X-Postmark-Server-Token header" do
      test_pid = self()

      :meck.expect(Finch, :request, fn req, Tymeslot.Finch, _opts ->
        send(test_pid, {:finch_request, req})
        {:ok, %Finch.Response{status: 200, headers: [], body: "{}"}}
      end)

      capture_log(fn ->
        PostmarkProbe.test_api_key(api_key: "my-secret-key")
      end)

      assert_receive {:finch_request, req}
      assert req.method == "GET"
      assert req.host == "api.postmarkapp.com"
      assert req.path == "/server"

      header_names = Enum.map(req.headers, fn {name, _val} -> name end)

      assert "x-postmark-server-token" in header_names or
               {"X-Postmark-Server-Token", "my-secret-key"} in req.headers
    end
  end
end
