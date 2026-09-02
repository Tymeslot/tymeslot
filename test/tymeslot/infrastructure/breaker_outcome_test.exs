defmodule Tymeslot.Infrastructure.BreakerOutcomeTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.BreakerOutcome

  describe "classify/1" do
    test "classifies :ok as :success" do
      assert BreakerOutcome.classify(:ok) == :success
    end

    test "classifies {:ok, _} as :success" do
      assert BreakerOutcome.classify({:ok, %{room_id: "abc"}}) == :success
    end

    test "classifies {:provider_error, _} as :failure regardless of reason shape" do
      assert BreakerOutcome.classify({:provider_error, :timeout}) == :failure
      assert BreakerOutcome.classify({:provider_error, "server on fire"}) == :failure
    end

    test "classifies a nested {:error, :circuit_open} as :ignore" do
      assert BreakerOutcome.classify({:error, :circuit_open}) == :ignore
    end

    test "classifies an unrecognised term as :success, matching execute_function/2's normalisation" do
      assert BreakerOutcome.classify(:some_other_value) == :success
      assert BreakerOutcome.classify(%{room_id: "abc"}) == :success
    end

    test "classifies transport reasons as :failure" do
      for reason <- [
            :timeout,
            :network_error,
            :closed,
            :econnrefused,
            :econnreset,
            :ehostunreach,
            :enetunreach,
            :etimedout,
            :nxdomain,
            :closed_by_peer,
            :socket_closed_remotely
          ] do
        assert BreakerOutcome.classify({:error, reason}) == :failure,
               "expected #{inspect(reason)} to classify as :failure"
      end
    end

    test "classifies transport exception structs as :failure" do
      assert BreakerOutcome.classify({:error, %Req.TransportError{reason: :timeout}}) == :failure
      assert BreakerOutcome.classify({:error, %Mint.TransportError{reason: :closed}}) == :failure
      assert BreakerOutcome.classify({:error, %Mint.HTTPError{reason: :closed}}) == :failure
    end

    test "classifies {:http_error, status, body} by status" do
      for status <- [500, 501, 503, 429, 408] do
        assert BreakerOutcome.classify({:error, {:http_error, status, "body"}}) == :failure,
               "expected status #{status} to classify as :failure"
      end

      for status <- [400, 401, 403, 404] do
        assert BreakerOutcome.classify({:error, {:http_error, status, "body"}}) == :ignore,
               "expected status #{status} to classify as :ignore"
      end
    end

    test "classifies {:http_error, status} (no body) the same as the three-tuple form" do
      assert BreakerOutcome.classify({:error, {:http_error, 500}}) == :failure
      assert BreakerOutcome.classify({:error, {:http_error, 404}}) == :ignore
    end

    test "classifies an Ecto.Changeset error as :ignore" do
      changeset =
        Changeset.add_error(Changeset.change({%{}, %{name: :string}}), :name, "can't be blank")

      assert BreakerOutcome.classify({:error, changeset}) == :ignore
    end

    test "classifies an unrecognised error reason as :ignore" do
      assert BreakerOutcome.classify({:error, :insufficient_scope}) == :ignore
      assert BreakerOutcome.classify({:error, :not_found}) == :ignore
      assert BreakerOutcome.classify({:error, "misconfigured"}) == :ignore
    end

    test "classifies a 3-element {:error, reason, message} tuple by its reason, ignoring the message" do
      assert BreakerOutcome.classify({:error, :network_error, "Network error: timeout"}) ==
               :failure

      assert BreakerOutcome.classify({:error, :rate_limited, "Too many requests"}) == :failure

      assert BreakerOutcome.classify({:error, :unauthorized, "Token expired or invalid"}) ==
               :ignore

      assert BreakerOutcome.classify({:error, :not_found, "Calendar not found"}) == :ignore
      assert BreakerOutcome.classify({:error, :gone, "sync token expired"}) == :ignore
    end

    test "classifies :rate_limited and :service_unavailable as :failure" do
      assert BreakerOutcome.classify({:error, :rate_limited}) == :failure
      assert BreakerOutcome.classify({:error, :service_unavailable}) == :failure
    end

    test "classifies :server_error as :failure, matching the 5xx status form" do
      # The name the calendar clients (`CalDAV.Http`, `Exchange.Client`) give a
      # 5xx once they have classified it, so it has to score the same as the
      # raw status the line below scores.
      assert BreakerOutcome.classify({:error, :server_error}) == :failure
      assert BreakerOutcome.classify({:error, {:http_error, 500, "body"}}) == :failure

      assert BreakerOutcome.classify({:error, :server_error, "The server reported an error"}) ==
               :failure
    end
  end

  describe "permanent_credential_error?/1" do
    test "recognises atom markers for a rejected or expired grant" do
      assert BreakerOutcome.permanent_credential_error?(:unauthorized)
      assert BreakerOutcome.permanent_credential_error?(:invalid_credentials)
      assert BreakerOutcome.permanent_credential_error?(:token_expired)
    end

    test "recognises string markers as whole-word tokens" do
      assert BreakerOutcome.permanent_credential_error?("invalid_grant")
      assert BreakerOutcome.permanent_credential_error?("OAuth error: invalid_client detected")
      assert BreakerOutcome.permanent_credential_error?("access_denied by the provider")
    end

    test "does not match a string marker embedded in a longer token" do
      refute BreakerOutcome.permanent_credential_error?("invalid_grant_period_started")
    end

    test "does not treat 'unauthorized origin' as a credential error, unlike the atom form" do
      refute BreakerOutcome.permanent_credential_error?("unauthorized origin")
    end

    test "recognises the marker inside an {:exception, message} tuple" do
      assert BreakerOutcome.permanent_credential_error?({:exception, "invalid_grant"})
      refute BreakerOutcome.permanent_credential_error?({:exception, "some other failure"})
    end

    test "returns false for non-UTF-8 binaries instead of raising" do
      refute BreakerOutcome.permanent_credential_error?(<<0xFF, 0xFE>>)
    end

    test "returns false for an unrecognised atom or other term" do
      refute BreakerOutcome.permanent_credential_error?(:some_other_atom)
      refute BreakerOutcome.permanent_credential_error?(%{})
      refute BreakerOutcome.permanent_credential_error?(nil)
    end
  end

  describe "error_tokens/1" do
    test "splits a reason into lowercased whole-word tokens" do
      assert BreakerOutcome.error_tokens("OAuth error: invalid_client detected") ==
               ["oauth", "error", "invalid_client", "detected"]
    end

    test "returns an empty list for a non-UTF-8 binary instead of raising" do
      assert BreakerOutcome.error_tokens(<<0xFF, 0xFE>>) == []
    end
  end
end
