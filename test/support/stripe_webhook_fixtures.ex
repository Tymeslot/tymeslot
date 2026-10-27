defmodule Tymeslot.StripeWebhookFixtures do
  @moduledoc """
  Stripe webhook bodies in the shape Stripe actually sends them, signed the
  way Stripe signs them.

  A webhook endpoint renders every event at the API version the endpoint was
  created with, not the version the client library pins. Both of Tymeslot's
  endpoints were created at `2020-08-27`, so the fixtures under
  `fixtures/stripe/2020-08-27/` carry that version's field set, including the
  fields later versions moved or removed (`charge.invoice`, a subscription's
  top-level `current_period_start`/`current_period_end`). Feed them through
  the real signature check so a test exercises the same decoding production
  does, rather than handing a pre-built map to a handler.
  """

  alias Tymeslot.PaymentTestHelpers

  @fixtures_dir Path.expand("fixtures/stripe/2020-08-27", __DIR__)

  @doc """
  Returns the JSON body of the named `2020-08-27` event (`"charge.refunded"`
  loads `charge.refunded.json`), with `object_overrides` merged into
  `data.object` and `event_overrides` into the event itself.
  """
  @spec body(String.t(), map(), map()) :: String.t()
  def body(name, object_overrides \\ %{}, event_overrides \\ %{}) do
    name
    |> event()
    |> update_in(["data", "object"], &Map.merge(&1, object_overrides))
    |> Map.merge(event_overrides)
    |> Jason.encode!()
  end

  @doc """
  Returns the named `2020-08-27` event, decoded.
  """
  @spec event(String.t()) :: map()
  def event(name) do
    @fixtures_dir
    |> Path.join(name <> ".json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Builds a valid `Stripe-Signature` header for `body` under `secret`.
  """
  @spec signature(String.t(), String.t()) :: String.t()
  def signature(body, secret), do: PaymentTestHelpers.generate_stripe_signature(body, secret)
end
