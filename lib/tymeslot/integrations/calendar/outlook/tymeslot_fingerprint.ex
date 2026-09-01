defmodule Tymeslot.Integrations.Calendar.Outlook.TymeslotFingerprint do
  @moduledoc """
  Single source for the Microsoft Graph MAPI extended-property id Tymeslot
  stamps onto (and later recognises on) events it created.

  `{00020329-0000-0000-C000-000000000046}` is the well-known MAPI property
  set GUID for `PidTagCreatorName` (`createdBy`); Tymeslot repurposes its
  `String` named-property slot to carry the `"tymeslot"` fingerprint value.
  `EventMapper` writes it, `EventNormaliser` reads it back to detect
  Tymeslot-origin events, and `CalendarAPI` filters Graph queries down to
  events carrying it — all three must agree on the exact id string.
  """

  @property_id "String {00020329-0000-0000-C000-000000000046} Name createdBy"

  @doc "The MAPI extended-property id used to fingerprint Tymeslot-created events."
  @spec property_id() :: String.t()
  def property_id, do: @property_id
end
