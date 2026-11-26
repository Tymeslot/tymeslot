defmodule Tymeslot.StripeLiveContract do
  @moduledoc """
  Pure helpers for the Stripe live suite: comparing a live response with the
  fixture that stands for it, and turning a live response into a fixture.

  A key path is a dotted string (`"charge.refunds.data.[].id"`); list elements
  share the `"[]"` segment, and nothing below a `metadata` key counts, since
  its keys belong to the caller.
  """

  # Step label => fixture name, or `{fixture, :first_of_list}` when the step
  # returns a list whose first element is the fixture's object.
  @fixtures %{
    "Customers.create" => "customer",
    "Customers.create (subscription flow)" => "customer",
    "Customers.delete" => "customer_deleted",
    "CheckoutSessions.create (subscription)" => "checkout_session_subscription",
    # An expired session keeps its mode's keys: compared with the subscription
    # one, not with `checkout_session_expired`, which is in payment mode.
    "CheckoutSessions.expire (subscription)" => "checkout_session_subscription",
    "Subscriptions.retrieve" => "subscription",
    "Subscriptions.update (cancel at period end)" => "subscription_canceling",
    "Subscriptions.cancel" => "subscription_canceled",
    "Invoices.retrieve" => "invoice",
    "BillingPortal.create_session" => "billing_portal_session",
    "PaymentIntents.retrieve" => "payment_intent_with_latest_charge",
    "Charges.retrieve" => "charge",
    "Charges.list (expand refunds)" => {"charge_with_refunds", :first_of_list},
    "Refunds.create" => "refund_with_charge",
    "Refunds.retrieve" => "refund",
    "Accounts.retrieve_connected" => "account",
    "CheckoutSessions.create (connect)" => "checkout_session_payment",
    "CheckoutSessions.expire (connect)" => "checkout_session_expired",
    "PaymentIntents.retrieve (connect)" => "payment_intent_with_latest_charge",
    "Charges.retrieve (connect)" => "charge",
    "Refunds.create (connect)" => "refund_with_charge"
  }

  @redacted_keys ~w(client_secret secret url hosted_invoice_url receipt_url invoice_pdf)
  # A link under a `*_url` or `*_pdf` key that opens a Stripe-hosted page carries a token.
  @hosted_page ~r{^https://(pay|invoice|checkout|billing|connect)\.stripe\.com}
  # `<prefix>_<token>` with a digit in the token: an object id (`cus_test1`,
  # `price_1Abc`), where an enum value such as `card_declined` has none.
  @object_id ~r/^([a-z]+(?:_[a-z]+)*)_(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{5,}$/

  # The step each fixture is recorded from, so a re-record does not depend on
  # the order the flows ran in. Other steps mapped above are only compared.
  @recorded_by [
    "Customers.create",
    "Customers.delete",
    "CheckoutSessions.create (subscription)",
    "Subscriptions.retrieve",
    "Subscriptions.update (cancel at period end)",
    "Subscriptions.cancel",
    "Invoices.retrieve",
    "BillingPortal.create_session",
    # The platform charge-and-refund flow records these four.
    "PaymentIntents.retrieve",
    "Charges.retrieve",
    "Charges.list (expand refunds)",
    "Refunds.create",
    "Refunds.retrieve",
    "Accounts.retrieve_connected",
    "CheckoutSessions.create (connect)",
    # The README describes this fixture in payment mode, so the connect flow records it.
    "CheckoutSessions.expire (connect)"
  ]
  @email ~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/

  @doc "The fixture name for a step label, or `nil` when it has none."
  @spec fixture_for(String.t()) :: String.t() | nil
  def fixture_for(label) do
    case Map.get(@fixtures, label) do
      {name, _shape} -> name
      name -> name
    end
  end

  @doc "The labels of the steps fixtures are recorded from."
  @spec recorded_labels() :: [String.t()]
  def recorded_labels, do: @recorded_by

  @doc "Whether the step is the one its fixture is recorded from."
  @spec recorded_by?(String.t()) :: boolean()
  def recorded_by?(label), do: label in @recorded_by

  @doc "The object a step's live response stands for, given its label."
  @spec target(String.t(), map()) :: map()
  def target(label, live) do
    case Map.get(@fixtures, label) do
      {_name, :first_of_list} -> live |> Map.get("data", []) |> List.first(%{})
      _plain -> live
    end
  end

  @doc "Every key path in `value`, sorted and unique."
  @spec key_paths(term()) :: [String.t()]
  def key_paths(value) do
    value |> walk([]) |> Enum.uniq() |> Enum.sort()
  end

  defp walk(map, path) when is_map(map) do
    Enum.flat_map(map, fn
      {"metadata", _value} -> [join(["metadata" | path])]
      {key, value} -> [join([key | path]) | walk(value, [key | path])]
    end)
  end

  defp walk(list, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, ["[]" | path]))
  defp walk(_scalar, _path), do: []

  defp join(reversed), do: reversed |> Enum.reverse() |> Enum.join(".")

  @doc """
  Compares a live object with its fixture: `drift` is what the fixture has and
  Stripe no longer sends, `new_keys` what Stripe sends that the fixture lacks.
  """
  @spec compare(map(), map()) :: %{drift: [String.t()], new_keys: [String.t()]}
  def compare(fixture, live) do
    fixture_paths = key_paths(fixture)
    live_paths = key_paths(live)
    %{drift: fixture_paths -- live_paths, new_keys: live_paths -- fixture_paths}
  end

  @doc """
  Pairs each fake id in `fixture` with the live id at the same position in
  `live`, returned as `%{live_id => fake_id}`.
  """
  @spec id_map(term(), term()) :: %{String.t() => String.t()}
  def id_map(fixture, live), do: collect_ids(fixture, live, %{})

  defp collect_ids(fake, live, acc) when is_binary(fake) and is_binary(live) do
    if fake != live and same_kind?(fake, live), do: Map.put(acc, live, fake), else: acc
  end

  defp collect_ids(fixture, live, acc) when is_map(fixture) and is_map(live) do
    Enum.reduce(fixture, acc, fn {key, fake}, acc ->
      case live do
        %{^key => value} -> collect_ids(fake, value, acc)
        _missing -> acc
      end
    end)
  end

  defp collect_ids(fixture, live, acc) when is_list(fixture) and is_list(live) do
    fixture |> Enum.zip(live) |> Enum.reduce(acc, fn {f, l}, acc -> collect_ids(f, l, acc) end)
  end

  defp collect_ids(_fixture, _live, acc), do: acc

  defp same_kind?(fake, live) do
    with [_whole, prefix] <- Regex.run(@object_id, fake),
         [_whole, live_prefix] <- Regex.run(@object_id, live) do
      object_kind(prefix) == object_kind(live_prefix)
    else
      _other -> false
    end
  end

  # A live id names its mode (`cs_test_a1B2…`) where a fixture id does not
  # (`cs_test1`), so the kind is the prefix without it.
  defp object_kind(prefix), do: String.replace(prefix, ~r/_(test|live)$/, "")

  @doc """
  Turns a live object into fixture content: live ids become their fixture ids,
  secrets and links are redacted (the keys stay, so readers still find a
  binary) and email addresses are replaced.
  """
  @spec sanitise(term(), %{String.t() => String.t()}) :: term()
  def sanitise(value, ids) do
    ordered = ids |> Map.to_list() |> Enum.sort_by(fn {live, _fake} -> -String.length(live) end)
    clean(value, ordered)
  end

  defp clean(map, ids) when is_map(map) do
    Map.new(map, fn
      # The suite's own markers (`live-<unix>`) are not what Stripe sends
      # Tymeslot: a fixture's metadata is what a request without any carries.
      {"metadata", %{} = metadata} ->
        {"metadata", Map.reject(metadata, fn {_key, v} -> live_marker?(v) end)}

      {key, value} when is_binary(value) ->
        {key, if(redact_key?(key, value), do: "redacted", else: clean(value, ids))}

      {key, value} ->
        {key, clean(value, ids)}
    end)
  end

  defp clean(list, ids) when is_list(list), do: Enum.map(list, &clean(&1, ids))

  defp clean(string, ids) when is_binary(string) do
    ids
    |> Enum.reduce(string, fn {live, fake}, acc -> String.replace(acc, live, fake) end)
    |> then(&Regex.replace(@email, &1, "customer@example.test"))
  end

  defp clean(other, _ids), do: other

  defp live_marker?(value), do: is_binary(value) and String.starts_with?(value, "live-")

  defp redact_key?(key, value) do
    key in @redacted_keys or
      (String.ends_with?(key, ["_url", "_pdf"]) and Regex.match?(@hosted_page, value))
  end

  @doc """
  Marks each named fixture's README row as recorded on `date`, replacing only
  the provenance text (`API reference example (...), fetched <date>`) and
  keeping the row's notes.
  """
  @spec mark_recorded(String.t(), [String.t()], String.t()) :: String.t()
  def mark_recorded(readme, names, date) do
    Enum.reduce(names, readme, fn name, text ->
      Regex.replace(
        ~r/^(\| `#{Regex.escape(name)}\.json` \| )(?:API reference example \([^)]*\), fetched [\d-]+|recorded [\d-]+)/m,
        text,
        "\\1recorded #{date}"
      )
    end)
  end
end
