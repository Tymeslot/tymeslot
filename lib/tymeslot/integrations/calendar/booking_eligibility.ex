defmodule Tymeslot.Integrations.Calendar.BookingEligibility do
  @moduledoc """
  The single answer to "can a booking be written to this integration?".

  A read-only provider (a subscribed feed, an Exchange mailbox) blocks
  availability perfectly well but refuses every write, so it must never be
  chosen as, promoted to, or accepted as a booking target: doing so leaves the
  user with a primary calendar that fails every booking, retries, and emails
  them about it, while a writable integration sat there unused.

  That rule was previously re-derived at every gate that selects a booking
  target, which is exactly how one provider ends up excluded from some of them
  and not others. Every such gate now calls this module, so adding a read-only
  provider is one edit in `ProviderConfig` and no edits here.

  Eligibility for reading busy time is a different question with a different
  answer: read-only integrations are fully eligible there, and nothing in this
  module applies to it.
  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @typedoc "Any integration-shaped map or schema struct carrying a provider."
  @type integration :: %{:provider => atom() | String.t() | nil, optional(any()) => any()}

  @doc """
  Checks whether an integration can be the calendar a booking is written to.
  """
  @spec bookable?(integration()) :: boolean()
  def bookable?(%{provider: provider}), do: not ProviderConfig.read_only?(provider)

  @doc """
  Keeps only the integrations a booking can be written to, preserving order.
  """
  @spec filter_bookable([integration()]) :: [integration()]
  def filter_bookable(integrations), do: Enum.filter(integrations, &bookable?/1)
end
