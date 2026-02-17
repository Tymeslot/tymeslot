defmodule Tymeslot.Payments.TaxExtractor do
  @moduledoc """
  Extracts and processes tax information from Stripe checkout sessions.

  This module consolidates tax extraction logic that was previously embedded
  in the CheckoutSessionHandler webhook handler. It provides reusable functions
  for extracting tax amounts, tax IDs, and determining EU business status.

  ## Configuration

  EU country codes can be configured via application config:

      config :tymeslot, :eu_country_codes, ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE)
  """

  @doc """
  Extracts comprehensive tax information from a Stripe checkout session.

  ## Parameters
    * `session` - The Stripe checkout session map

  ## Returns
    A map containing:
    * `:tax_amount` - Tax amount in cents (integer)
    * `:country_code` - ISO country code (string or nil)
    * `:tax_id` - Customer's tax ID (string or nil)
    * `:is_eu_business` - Whether customer is an EU business (boolean)
    * `:billing_address` - Full billing address map (map or nil)

  ## Examples

      iex> TaxExtractor.extract_tax_info(session)
      %{
        tax_amount: 500,
        country_code: "DE",
        tax_id: "DE123456789",
        is_eu_business: true,
        billing_address: %{"country" => "DE", "line1" => "..."}
      }
  """
  @spec extract_tax_info(map()) :: map()
  def extract_tax_info(session) do
    %{
      tax_amount: extract_tax_amount(session),
      country_code: get_in(session, ["customer_details", "address", "country"]),
      tax_id: extract_tax_id(session),
      is_eu_business: eu_business?(session),
      billing_address: get_in(session, ["customer_details", "address"])
    }
  end

  @doc """
  Extracts the tax amount from a Stripe checkout session.

  Stripe sends tax amounts in cents. This function ensures the value is
  properly parsed as an integer, handling various input formats.

  ## Parameters
    * `session` - The Stripe checkout session map

  ## Returns
    Tax amount in cents as an integer. Returns 0 if no tax amount is present
    or if the value cannot be parsed.

  ## Examples

      iex> TaxExtractor.extract_tax_amount(%{"total_details" => %{"amount_tax" => 500}})
      500

      iex> TaxExtractor.extract_tax_amount(%{"total_details" => %{"amount_tax" => "500"}})
      500

      iex> TaxExtractor.extract_tax_amount(%{})
      0
  """
  @spec extract_tax_amount(map()) :: non_neg_integer()
  def extract_tax_amount(session) do
    raw_tax_amount = get_in(session, ["total_details", "amount_tax"])

    case raw_tax_amount do
      nil ->
        0

      amount when is_integer(amount) ->
        amount

      amount when is_binary(amount) ->
        case Integer.parse(amount) do
          {parsed, _value} -> parsed
          :error -> 0
        end

      _other ->
        0
    end
  end

  @doc """
  Extracts the customer's tax ID from a Stripe checkout session.

  Retrieves the first tax ID from the customer details. Stripe allows multiple
  tax IDs, but we currently only use the first one.

  ## Parameters
    * `session` - The Stripe checkout session map

  ## Returns
    The tax ID value as a string, or `nil` if no tax ID is present.

  ## Examples

      iex> session = %{
      ...>   "customer_details" => %{
      ...>     "tax_ids" => [%{"type" => "eu_vat", "value" => "DE123456789"}]
      ...>   }
      ...> }
      iex> TaxExtractor.extract_tax_id(session)
      "DE123456789"

      iex> TaxExtractor.extract_tax_id(%{})
      nil
  """
  @spec extract_tax_id(map()) :: String.t() | nil
  def extract_tax_id(session) do
    case get_in(session, ["customer_details", "tax_ids"]) do
      tax_ids when is_list(tax_ids) and tax_ids != [] ->
        tax_ids |> List.first() |> Map.get("value", nil)

      _other ->
        nil
    end
  end

  @doc """
  Determines if the customer is an EU business based on tax ID and country.

  A customer is considered an EU business if:
  1. They have a tax ID of type "eu_vat"
  2. Their billing country is in the EU country list

  ## Parameters
    * `session` - The Stripe checkout session map

  ## Returns
    `true` if the customer is an EU business, `false` otherwise.

  ## Examples

      iex> session = %{
      ...>   "customer_details" => %{
      ...>     "tax_ids" => [%{"type" => "eu_vat"}],
      ...>     "address" => %{"country" => "DE"}
      ...>   }
      ...> }
      iex> TaxExtractor.eu_business?(session)
      true

      iex> session = %{
      ...>   "customer_details" => %{
      ...>     "tax_ids" => [%{"type" => "us_ein"}],
      ...>     "address" => %{"country" => "US"}
      ...>   }
      ...> }
      iex> TaxExtractor.eu_business?(session)
      false
  """
  @spec eu_business?(map()) :: boolean()
  def eu_business?(session) do
    tax_ids = get_in(session, ["customer_details", "tax_ids"]) || []
    country = get_in(session, ["customer_details", "address", "country"])

    has_eu_vat =
      Enum.any?(tax_ids, fn
        %{"type" => "eu_vat"} -> true
        _other -> false
      end)

    has_eu_vat and country != nil and country in eu_country_codes()
  end

  @doc """
  Returns the list of EU country codes.

  Can be configured via application config:

      config :tymeslot, :eu_country_codes, ~w(AT BE BG ...)

  ## Returns
    List of ISO country codes for EU member states.
  """
  @spec eu_country_codes() :: [String.t()]
  def eu_country_codes do
    Application.get_env(
      :tymeslot,
      :eu_country_codes,
      ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE)
    )
  end
end
