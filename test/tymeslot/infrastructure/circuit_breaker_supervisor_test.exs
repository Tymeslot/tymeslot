defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

  describe "supervisor started" do
    test "CircuitBreakerSupervisor is running" do
      assert is_pid(Process.whereis(Tymeslot.Infrastructure.CircuitBreakerSupervisor))
    end
  end

  describe "calendar breakers" do
    test "all calendar provider breakers are alive" do
      providers =
        Enum.filter(
          CalendarProviderConfig.all_providers(),
          &CalendarProviderConfig.circuit_breaker_enabled?/1
        )

      for provider <- providers do
        breaker_name = "calendar_breaker_#{provider}"

        name =
          try do
            String.to_existing_atom(breaker_name)
          rescue
            ArgumentError ->
              flunk("Atom #{breaker_name} not found — is CircuitBreakerSupervisor running?")
          end

        assert Process.whereis(name) != nil, "Expected #{name} to be running"
        assert %{status: :closed} = CircuitBreaker.status(name)
      end
    end
  end

  describe "video breakers" do
    test "all video provider breakers are alive" do
      providers =
        Enum.filter(
          VideoProviderConfig.all_providers(),
          &VideoProviderConfig.circuit_breaker_enabled?/1
        )

      for provider <- providers do
        breaker_name = "video_breaker_#{provider}"

        name =
          try do
            String.to_existing_atom(breaker_name)
          rescue
            ArgumentError ->
              flunk("Atom #{breaker_name} not found — is CircuitBreakerSupervisor running?")
          end

        assert Process.whereis(name) != nil, "Expected #{name} to be running"
        assert %{status: :closed} = CircuitBreaker.status(name)
      end
    end
  end

  describe "other breakers" do
    test "email service breaker is alive" do
      assert Process.whereis(:email_service_breaker) != nil
      assert %{status: :closed} = CircuitBreaker.status(:email_service_breaker)
    end

    test "OAuth GitHub breaker is alive" do
      assert Process.whereis(:oauth_github_breaker) != nil
      assert %{status: :closed} = CircuitBreaker.status(:oauth_github_breaker)
    end

    test "OAuth Google breaker is alive" do
      assert Process.whereis(:oauth_google_breaker) != nil
      assert %{status: :closed} = CircuitBreaker.status(:oauth_google_breaker)
    end
  end

  describe "Registry and DynamicSupervisor" do
    test "CircuitBreakerRegistry is available" do
      assert Process.whereis(Tymeslot.Infrastructure.CircuitBreakerRegistry) != nil
    end

    test "DynamicCircuitBreakerSupervisor is available" do
      assert Process.whereis(Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor) != nil
    end
  end
end
