defmodule Tymeslot.Infrastructure.ErrorTracking.Filter do
  @moduledoc """
  Sanitises an ErrorTracker occurrence's context before it is stored.

  The context is whatever the integrations and `ErrorTracker.set_context/1`
  gathered: request headers and params, LiveView params, Oban job args. Two
  passes, each reusing the rule the rest of the system already applies:

  1. `Tymeslot.Infrastructure.Logging.MetadataRedactor.redact/1` blanks every
     value under a sensitive key (credentials, tokens, cookies, `*_email`),
     at any depth, for atom and string keys alike.
  2. `Tymeslot.Infrastructure.AdminAlerts.PIIScrubber.mask_emails/1` masks any
     email address left in a free-form string value.

  Keys are never rewritten, so the stored context keeps its shape.
  """

  @behaviour ErrorTracker.Filter

  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  @impl ErrorTracker.Filter
  def sanitize(context) when is_map(context) do
    context
    |> MetadataRedactor.redact()
    |> mask_emails()
  end

  defp mask_emails(value) when is_binary(value), do: PIIScrubber.mask_emails(value)
  defp mask_emails(value) when is_list(value), do: Enum.map(value, &mask_emails/1)

  # `:maps.map/2` rather than `Map.new/2`: a struct is a map without
  # `Enumerable`, and it must stay the struct it was.
  defp mask_emails(value) when is_map(value),
    do: :maps.map(fn _key, nested -> mask_emails(nested) end, value)

  defp mask_emails(value), do: value
end
