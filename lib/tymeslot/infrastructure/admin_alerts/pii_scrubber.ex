defmodule Tymeslot.Infrastructure.AdminAlerts.PIIScrubber do
  @moduledoc """
  Masks personal data in admin alert payloads at the notifier boundary.

  Two layers of defence:

  1. **Email keys** — a key that names an email address, by the same rule
     the log redactor uses (`MetadataRedactor.email_key?/1`: `owner_email`,
     `attendee_email`, `admin_recipient`), is rewritten to a masked variant
     (`owner_email` → `owner_email_masked` with value `a***@example.com`) or
     dropped entirely if the value is not a single address.

  2. **Regex sweep** — every remaining string value is scanned for embedded
     email addresses and masked in place (`Logging.EmailMasker`), catching an
     address that slipped into a `summary`, `reason_message`, or other
     free-form field.

  Nested maps are walked to the log redactor's depth, so an address under a
  `context` map is masked like one at the top. The scrubber is idempotent:
  running it on already-masked data is a no-op.

  Internal IDs (`user_id`, `meeting_id`, `dispute_id`, `charge_id`,
  `customer_id`, `event_id`, `integration_id`) are left visible — they
  are how operators pivot from an alert to a database record or a
  Stripe dashboard entry.
  """

  alias Tymeslot.Infrastructure.Logging.{EmailMasker, MetadataRedactor}

  # The masked keys of the email keys alerts carry today, as atoms, so their
  # readers (`AlertTypes`) can match on them without creating atoms at
  # runtime. Any other email key is masked under a string key.
  @masked_atom_keys Map.new(
                      ~w(owner_email customer_email email user_email recipient_email)a,
                      fn key -> {key, String.to_atom("#{key}_masked")} end
                    )

  @spec scrub(map()) :: map()
  def scrub(payload) when is_map(payload), do: scrub_map(payload, MetadataRedactor.max_depth())

  defp scrub_map(map, depth), do: Enum.reduce(map, %{}, &scrub_entry(&1, &2, depth))

  defp scrub_entry({key, value}, acc, depth) do
    cond do
      MetadataRedactor.email_key?(key) ->
        mask_address(acc, key, value)

      is_map(value) and not is_struct(value) and depth > 1 ->
        Map.put(acc, key, scrub_map(value, depth - 1))

      is_binary(value) ->
        Map.put(acc, key, EmailMasker.mask_emails(value))

      true ->
        Map.put(acc, key, value)
    end
  end

  defp mask_address(acc, key, value) when is_binary(value) do
    case EmailMasker.mask_email(String.trim(value)) do
      nil -> acc
      masked -> Map.put(acc, masked_key(key), masked)
    end
  end

  defp mask_address(acc, _key, _value), do: acc

  defp masked_key(key) when is_map_key(@masked_atom_keys, key),
    do: Map.fetch!(@masked_atom_keys, key)

  defp masked_key(key), do: "#{key}_masked"
end
