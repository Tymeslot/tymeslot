defmodule Tymeslot.AuthTestHelpers do
  @moduledoc """
  Helper functions for authentication tests.

  This module provides utilities for:
  - Logging in users in tests
  - Asserting authentication states
  - Creating test tokens
  - Mocking OAuth responses
  """

  import ExUnit.Assertions
  import Plug.Conn, only: [get_session: 2]

  alias Phoenix.ConnTest
  alias Plug.Conn
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{PasswordReset, Session}
  alias Tymeslot.Factory
  alias Tymeslot.Security.Token

  @doc """
  Logs in a user for controller/LiveView tests.
  """
  @spec log_in_user(Conn.t(), term()) :: Conn.t()
  def log_in_user(conn, user) do
    assert {:ok, conn, _token} = Session.create_session(conn, user)
    conn
  end

  @doc """
  Asserts that a user is logged in.
  """
  @spec assert_logged_in(Conn.t(), term()) :: term()
  def assert_logged_in(conn, user) do
    assert get_session(conn, :user_token)
    assert conn.assigns[:current_user]
    assert conn.assigns.current_user.id == user.id
  end

  @doc """
  Asserts that no user is logged in.
  """
  @spec assert_not_logged_in(Conn.t()) :: term()
  def assert_not_logged_in(conn) do
    refute get_session(conn, :user_token)
    refute conn.assigns[:current_user]
  end

  @doc """
  Creates a valid OAuth state for testing.
  """
  @spec create_oauth_state(Conn.t()) :: Conn.t()
  def create_oauth_state(conn) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32))

    conn
    |> ConnTest.init_test_session(%{})
    |> Conn.put_session(:oauth_state, state)
    |> Map.put(:state, state)
  end

  @doc """
  Asserts that an email was sent to the given address.
  """
  @spec assert_email_sent(keyword()) :: term()
  def assert_email_sent(to: email) do
    assert_receive {:delivered_email, delivered_email}, 1000
    assert delivered_email.to == [{nil, email}]
  end

  @spec assert_email_sent(keyword()) :: term()
  def assert_email_sent(to: email, subject: subject) do
    assert_receive {:delivered_email, delivered_email}, 1000
    assert delivered_email.to == [{nil, email}]
    assert delivered_email.subject =~ subject
  end

  @doc """
  Clears rate limiting for a given IP or email.
  """
  @spec clear_rate_limits(String.t()) :: true
  def clear_rate_limits(identifier) do
    key = "auth_attempt:#{identifier}"
    :ets.delete(:rate_limiter, key)
  end

  @doc """
  Clears all rate limits (useful in setup).
  """
  @spec clear_all_rate_limits() :: true
  def clear_all_rate_limits do
    :ets.delete_all_objects(:rate_limiter)
  end

  @doc """
  Creates a verified user with all common attributes.
  """
  @spec create_verified_user(map()) :: term()
  def create_verified_user(attrs \\ %{}) do
    Factory.insert(
      :user,
      Map.merge(
        %{
          email_verified: true,
          email_verified_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  @doc """
  Creates an OAuth user.
  """
  @spec create_oauth_user(String.t(), map()) :: term()
  def create_oauth_user(provider, attrs \\ %{}) do
    Factory.insert(
      :user,
      Map.merge(
        %{
          provider: provider,
          provider_uid: "oauth_#{System.unique_integer([:positive])}",
          email_verified: true,
          email_verified_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  @doc """
  Triggers account lockout for a user.
  """
  @spec trigger_account_lockout(term()) :: term()
  def trigger_account_lockout(user) do
    # Make multiple failed login attempts
    for _ <- 1..5 do
      Auth.authenticate_user(user.email, "wrong_password")
    end
  end

  @doc """
  Generates a valid password reset token for testing.
  """
  @spec generate_password_reset_token(term()) :: binary()
  def generate_password_reset_token(user) do
    assert {:ok, _status, _message} = PasswordReset.initiate_reset(user.email)
    Token.generate_token()
  end

  @doc """
  Generates a valid email verification token for testing.
  """
  @spec generate_email_verification_token(term()) :: binary()
  def generate_email_verification_token(_user) do
    Token.generate_token()
  end
end
