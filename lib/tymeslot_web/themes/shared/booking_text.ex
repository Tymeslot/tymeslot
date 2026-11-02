defmodule TymeslotWeb.Themes.Shared.BookingText do
  @moduledoc """
  Resolves the booking page's introductory copy: the organiser's own wording
  when they have turned the customisation on, the theme's translated default
  otherwise.

  Every theme with an overview step renders the same three slots, so the
  resolution lives here rather than in each theme. The heading default follows
  the theme's `heading_style` catalogue fact (`:generic` for a greeting,
  `:named` to name the organiser), so a new theme picks a style in the
  catalogue rather than a clause here; the greeting and instruction defaults are
  identical everywhere.

  The defaults live here rather than inline in each theme because the dashboard
  has to show an organiser what a single custom heading replaces in *both*
  themes, which is cross-theme knowledge no individual theme may hold. Themes
  still own the name they introduce themselves by, and pass it in: Rhythm
  substitutes a friendly word when the profile has no name, Quill drops the
  greeting instead.

  Each line is asked of the theme's voice first (`TymeslotWeb.Themes.Shared.Voice`),
  given the theme's catalogue key; without a key, or for a line the voice
  leaves alone, it is the shared wording below.

  The heading is always said. The greeting and the instruction are optional:
  a voice may leave either unsaid (`""`), and so may the organiser, whose
  blank line is not replaced by a default. `greeting/3` and `instruction/2`
  return `nil` for an unsaid line, and every theme renders nothing for it.

  The stored wording is a single string, not a per-locale map, matching the
  meeting type names and descriptions rendered directly beneath it on the same
  screen. Turning the customisation on therefore opts these three strings out of
  translation, which is the same trade the rest of the organiser's copy already
  makes.

  It also owns the meeting-length label every step shows, `duration_label/1`, so
  the themes cannot disagree about which duration wins, and a paid meeting
  type's price, `price_label/3`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Components.PaymentHelpers
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.Voice

  @type theme_key :: Catalog.theme_key()

  @doc """
  The page's introductory heading, given the theme whose default applies and the
  name that theme introduces the organiser by.
  """
  @spec heading(ProfileSchema.t() | nil, theme_key(), String.t() | nil) :: String.t()
  def heading(profile, theme_key, name),
    do: custom(profile, :booking_heading) || default_heading(theme_key, name)

  @doc """
  The greeting line, in the voice of the theme with key `theme_key` where it
  has one, or `nil` for no greeting, which the theme renders as nothing at all.

  It is `nil` when there is no name to introduce (rather than half a
  sentence), when the theme's voice leaves the greeting unsaid (`""`), and
  when the organiser's own wording leaves it blank: with the customisation on,
  the organiser's line is the greeting, blank included, and no default stands
  in for it.
  """
  @spec greeting(ProfileSchema.t() | nil, String.t() | nil, theme_key() | nil) ::
          String.t() | nil
  def greeting(profile, name, theme_key \\ nil),
    do: optional(profile, :booking_greeting, fn -> default_greeting(name, theme_key) end)

  @doc """
  The line telling the visitor what to do next, in the voice of the theme
  with key `theme_key` where it has one, or `nil` for none: the voice leaves
  it unsaid (`""`), or the organiser's own wording leaves it blank. As with
  `greeting/3`, the theme renders nothing for `nil`.
  """
  @spec instruction(ProfileSchema.t() | nil, theme_key() | nil) :: String.t() | nil
  def instruction(profile, theme_key \\ nil),
    do: optional(profile, :booking_instruction, fn -> default_instruction(theme_key) end)

  @doc """
  The heading a theme shows when the organiser has not supplied one: its
  voice's, else the shared wording for its heading style.

  A theme that introduces the organiser by name falls back to the generic
  heading when there is no name, rather than to a filler word.
  """
  @spec default_heading(theme_key(), String.t() | nil) :: String.t()
  def default_heading(theme_key, name) do
    voice = Voice.of(theme_key)

    case {heading_style(theme_key), name} do
      {:named, name} when is_binary(name) ->
        Voice.line(voice, :heading_named, %{name: name}, fn ->
          dgettext("booking", "Schedule with %{name}", name: name)
        end)

      _generic_or_nameless ->
        Voice.line(voice, :heading, %{}, fn -> dgettext("booking", "Let's Connect!") end)
    end
  end

  # A key the catalogue does not know takes the default theme's style.
  defp heading_style(theme_key) do
    case Map.fetch(Catalog.all(), theme_key) do
      {:ok, %{heading_style: style}} -> style
      :error -> Catalog.default().heading_style
    end
  end

  @doc """
  The greeting shown when the organiser has not supplied one, or `nil` when
  there is no name to introduce. `""` when the theme's voice says nothing
  for the greeting; `greeting/3` turns that into `nil`, the dashboard seeds
  its field with it.
  """
  @spec default_greeting(String.t() | nil, theme_key() | nil) :: String.t() | nil
  def default_greeting(name, theme_key \\ nil)
  def default_greeting(nil, _theme_key), do: nil
  def default_greeting(name, theme_key), do: voiced_greeting(name, theme_key)

  @doc """
  A greeting to start the organiser off with when they switch the customisation
  on, which unlike `default_greeting/2` is never `nil`: the theme's own line,
  `""` included for a voice that greets nobody, so switching the customisation
  on changes nothing on the page until the organiser edits a line.

  A profile with no name gets a friendly line without one, which the
  organiser keeps, edits or clears; the public page's default drops the
  greeting in that case. A voice that leaves the greeting unsaid seeds `""`
  there too: its `""` does not depend on the name (`Voice`), so asking it
  with an empty one tells whether it greets at all.
  """
  @spec seed_greeting(String.t() | nil, theme_key() | nil) :: String.t()
  def seed_greeting(name, theme_key \\ nil)

  def seed_greeting(nil, theme_key) do
    case voiced_greeting("", theme_key) do
      "" -> ""
      _greets -> dgettext("booking", "Hi there!")
    end
  end

  def seed_greeting(name, theme_key), do: voiced_greeting(name, theme_key)

  defp voiced_greeting(name, theme_key) do
    Voice.line(Voice.of(theme_key), :greeting, %{name: name}, fn ->
      dgettext("booking", "Hi! I'm %{name}.", name: name)
    end)
  end

  @doc """
  The instruction shown when the organiser has not supplied one, or `""`
  when the theme's voice says nothing for it.
  """
  @spec default_instruction(theme_key() | nil) :: String.t()
  def default_instruction(theme_key \\ nil) do
    Voice.line(Voice.of(theme_key), :instruction, %{}, fn ->
      dgettext("booking", "Pick an option to get started.")
    end)
  end

  defp custom(%{booking_text_enabled: true} = profile, field), do: Map.get(profile, field)
  defp custom(_profile, _field), do: nil

  # A line the page may leave out: with the customisation on, the organiser's
  # wording is the line even when blank; otherwise the theme's default. Blank
  # comes back as `nil`, so a theme tests one value before rendering.
  defp optional(%{booking_text_enabled: true} = profile, field, _default),
    do: present(Map.get(profile, field))

  defp optional(_profile, _field, default), do: present(default.())

  defp present(nil), do: nil
  defp present(text), do: if(String.trim(text) == "", do: nil, else: text)

  @doc """
  The meeting's length as a step shows it: the meeting type's own duration
  when the page has resolved one, or the length the booking is for when the
  type offers several (`ChosenLength.minutes/1`), otherwise the duration
  selected in the URL (`:duration`, e.g. `"30-minutes"`).

  Takes a map with `:meeting_type` and `:duration`, and the length assigns, so
  a step component can pass its assigns straight through; a component whose
  selected duration lives under another key builds the map itself.
  """
  @spec duration_label(map()) :: String.t()
  def duration_label(%{meeting_type: %{duration_minutes: minutes} = meeting_type} = assigns)
      when is_integer(minutes),
      do:
        LocalizationHelpers.format_duration(
          Offer.duration_minutes(meeting_type, nil, ChosenLength.minutes(assigns))
        )

  def duration_label(assigns),
    do: LocalizationHelpers.format_duration(Map.get(assigns, :duration))

  @doc """
  A paid meeting type's price in the organiser's currency (`@host_currency`,
  which the page holds from mount), written the way the guest's `locale`
  writes amounts ("€45.00", "45,00 €"), or `nil` for a free type, for a paid
  one without a price, and when the currency is unknown. A demo persona's
  meeting type is a plain map without the fields, and is `nil` too.
  """
  @spec price_label(map() | nil, String.t() | nil, String.t()) :: String.t() | nil
  def price_label(%{payment_required: true, price_cents: cents}, currency, locale)
      when is_integer(cents) and cents > 0 and is_binary(currency),
      do: PaymentHelpers.format_amount(cents, currency, locale)

  def price_label(_meeting_type, _currency, _locale), do: nil

  @doc """
  A meeting type's description as the booker reads it, or `nil` when it has
  none to show: a blank one is left out rather than drawn empty. A demo
  persona's meeting type is a plain map, so the field is read with `Map.get/2`.
  """
  @spec description(map() | nil) :: String.t() | nil
  def description(%{} = meeting_type) do
    case Map.get(meeting_type, :description) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
      _none -> nil
    end
  end

  def description(nil), do: nil
end
