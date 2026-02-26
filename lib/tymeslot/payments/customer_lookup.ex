defmodule Tymeslot.Payments.CustomerLookup do
  @moduledoc """
  Centralized customer lookup utilities for payment operations.

  Provides functions to parse and validate user IDs from various sources.

  Note: Subscription-related lookups are delegated to SaaS layer when configured
  to maintain proper Core/SaaS separation.
  """

  require Logger

  alias Tymeslot.Payments.Config

  @doc """
  Parses a user ID from metadata, handling both integer and string formats.

  Only accepts complete integer parses - partial matches like "42abc" are rejected.

  ## Examples

      iex> parse_user_id(42)
      42

      iex> parse_user_id("42")
      42

      iex> parse_user_id("42abc")
      nil

      iex> parse_user_id(nil)
      nil
  """
  @spec parse_user_id(any()) :: integer() | nil
  def parse_user_id(nil), do: nil
  def parse_user_id(id) when is_integer(id), do: id

  def parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _other -> nil
    end
  end

  def parse_user_id(_invalid), do: nil

  @doc """
  Gets the full subscription record by Stripe customer ID.

  This function is used by Core webhook handlers but delegates to SaaS-configured
  subscription schema when available. Returns `nil` if no subscription schema is
  configured (Core standalone mode) or no subscription is found.

  Note: In SaaS deployments, the SaaS layer provides direct access to subscription
  schema without configuration indirection.

  ## Parameters
    * `stripe_customer_id` - The Stripe customer ID to look up

  ## Returns
    * Subscription struct if found
    * `nil` if no subscription found or no subscription schema configured
  """
  @spec get_subscription_by_customer_id(String.t() | nil) :: struct() | nil
  def get_subscription_by_customer_id(nil), do: nil

  def get_subscription_by_customer_id(stripe_customer_id) when is_binary(stripe_customer_id) do
    repo = Config.repo()
    subscription_schema = Config.subscription_schema()

    if subscription_schema && Code.ensure_loaded?(subscription_schema) do
      case repo.get_by(subscription_schema, stripe_customer_id: stripe_customer_id) do
        nil ->
          Logger.debug("No subscription found for Stripe customer", stripe_customer_id: stripe_customer_id)
          nil

        subscription ->
          Logger.debug("Found subscription for Stripe customer", stripe_customer_id: stripe_customer_id)
          subscription
      end
    else
      Logger.debug("Subscription schema not configured - subscription lookup skipped",
        stripe_customer_id: stripe_customer_id
      )

      nil
    end
  end
end
