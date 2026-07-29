defmodule Tymeslot.Integrations.Calendar.Reminder do
  @moduledoc """
  The single source of truth for Tymeslot's per-event reminder shape.

  A reminder carries two fields: a **method** (`:popup`, `:email`, or `:sms`)
  and a **lead time** in minutes (`minutes_before`). The canonical shape is an
  atom-keyed map:

      %{method: :popup | :email | :sms, minutes_before: non_neg_integer()}

  Reminders are stored in a JSONB column, which means any atom-keyed map written
  by the UI or create flow comes back from the database string-keyed. Both key
  forms are accepted everywhere in this module; callers should use `normalise/1`
  to produce the canonical atom-keyed shape before passing reminders further.

  ## Provider projections

  - **Google Calendar** — reminders sync as named overrides with a `"method"`
    string (`"popup"` or `"email"`) and a `"minutes"` integer.
  - **iCalendar / CalDAV** — reminders emit as `VALARM` components with an
    `ACTION` property (`"DISPLAY"` or `"EMAIL"`).
  - **Outlook / Microsoft Graph** — the Graph API supports a single integer
    lead-time per event (`reminderMinutesBeforeStart`); method is not
    representable. Only the first reminder's `minutes_before` round-trips.

  ## SMS degradation

  Neither Google Calendar nor the iCalendar `VALARM` spec defines a native SMS
  action. `:sms` reminders therefore degrade consistently:

  - `google_method/1` for `:sms` → `"popup"`
  - `ical_action/1` for `:sms` → `"DISPLAY"`

  The `:sms` method atom is preserved in the normalised canonical shape so that
  the application layer (e.g. the reminder UI) can still identify and display it
  correctly; degradation only happens at the provider boundary.
  """

  @typedoc "The canonical reminder method atom."
  @type method :: :popup | :email | :sms

  @typedoc "A canonical reminder map."
  @type t :: %{method: method(), minutes_before: non_neg_integer()}

  @doc """
  Normalises a raw reminder map into the canonical atom-keyed shape.

  Accepts both atom-keyed maps (freshly built in the create/edit flow) and
  string-keyed maps (round-tripped through the JSONB cache column). Returns a
  map with `:method` and `:minutes_before` keys, with the method coerced to the
  appropriate atom via `method/1`.
  """
  @spec normalise(map()) :: t()
  def normalise(%{} = reminder) do
    %{
      method: method(reminder),
      minutes_before: fetch_minutes_before(reminder)
    }
  end

  @doc """
  Returns the canonical method atom from a (possibly string-keyed) reminder map.

  Recognised values for the `method` / `"method"` key:

  - `"email"` / `:email` → `:email`
  - `"sms"` / `:sms` → `:sms`
  - anything else (including `"popup"`, `:popup`, `nil`) → `:popup`
  """
  @spec method(map()) :: method()
  def method(%{method: raw}), do: method_atom(raw)
  def method(%{"method" => raw}), do: method_atom(raw)
  def method(%{}), do: method_atom(nil)

  @doc """
  Maps the canonical reminder method to a Google Calendar override method string.

  Google supports `"popup"` and `"email"`. `:sms` degrades to `"popup"` since
  Google has no native SMS reminder type.
  """
  @spec google_method(method() | String.t() | nil) :: String.t()
  def google_method(:email), do: "email"
  def google_method("email"), do: "email"
  def google_method(_popup_or_sms_or_other), do: "popup"

  @doc """
  Maps the canonical reminder method to an iCalendar VALARM `ACTION` string.

  RFC 5545 defines `DISPLAY`, `EMAIL`, and `AUDIO` actions. `:sms` degrades to
  `"DISPLAY"` since iCalendar has no native SMS action.
  """
  @spec ical_action(method() | String.t() | nil) :: String.t()
  def ical_action(:email), do: "EMAIL"
  def ical_action("email"), do: "EMAIL"
  def ical_action(_display_or_sms_or_other), do: "DISPLAY"

  @doc """
  Extracts the `minutes_before` value from a (possibly string-keyed) reminder map.

  Used on the Outlook path, which only uses the first reminder's lead time.
  """
  @spec minutes_before(map()) :: non_neg_integer() | nil
  def minutes_before(%{} = reminder) do
    fetch_minutes_before(reminder)
  end

  # --- Private helpers ---

  defp method_atom(:email), do: :email
  defp method_atom("email"), do: :email
  defp method_atom(:sms), do: :sms
  defp method_atom("sms"), do: :sms
  defp method_atom(_popup_or_other), do: :popup

  # Returns the `minutes_before` value, correctly handling `0`.
  # `||` is not used here because `0` is falsy in Elixir; pattern-matching on
  # the map key avoids silently promoting a `0` to the fallback branch.
  defp fetch_minutes_before(%{minutes_before: v}), do: v
  defp fetch_minutes_before(%{"minutes_before" => v}), do: v
  defp fetch_minutes_before(_reminder), do: nil
end
