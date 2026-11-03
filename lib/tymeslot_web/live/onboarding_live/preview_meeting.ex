defmodule TymeslotWeb.OnboardingLive.PreviewMeeting do
  @moduledoc """
  The meeting the onboarding previews name above the times: its name, its
  length and an icon for where it is held, drawn by `PreviewWeek.times/1`
  in each theme's own idiom (`meeting_line/1`).

  `view/1` turns the wizard's form state (`%{name, duration_minutes,
  location}`, `MeetingHandlers.meeting_preview/1`) into what is drawn,
  worded in the current locale; `PreviewWeek.view/4` puts it on the week's
  view as `meeting`.
  """

  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @typedoc "The meeting as drawn: its name, its length worded, and a place icon."
  @type t :: %{name: String.t(), duration: String.t() | nil, icon: String.t()}

  # Where the meeting is held, as an icon; an unknown or unset place shows
  # the generic one.
  @location_icons %{
    video: "hero-video-camera",
    phone: "hero-phone",
    in_person: "hero-map-pin"
  }

  @doc "What the line draws for the form's meeting, or `nil` without a name."
  @spec view(map() | nil) :: t() | nil
  def view(%{name: name} = meeting) when is_binary(name) and name != "" do
    %{
      name: name,
      duration: duration(meeting[:duration_minutes]),
      icon: Map.get(@location_icons, meeting[:location], "hero-calendar")
    }
  end

  def view(_meeting), do: nil

  defp duration(minutes) when is_integer(minutes) and minutes > 0,
    do: LocalizationHelpers.format_duration(minutes)

  defp duration(_minutes), do: nil

  attr :meeting, :map, required: true, doc: "the view's `meeting`"
  attr :colors, :map, required: true
  attr :variant, :atom, required: true

  @doc """
  The meeting the page offers, in one line: its name, its length and an
  icon for where it is held. Each theme draws it in its own idiom:

    * `:bar` - left-aligned behind a short bar in the primary colour
    * `:pill` - centred in a pill tinted with the primary colour
    * `:rule` - centred between two thin rules, as a section title
    * `:plain` - left-aligned, the name above its length and place in the
      muted colour, for a narrow column
  """
  @spec meeting_line(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_line(%{variant: :pill} = assigns) do
    ~H"""
    <p
      class="self-center max-w-full min-w-0 inline-flex items-center gap-1.5 px-3 py-1 rounded-token-full text-token-xs font-semibold"
      style={"background: #{primary(@colors)}1f;color: #{ink(@colors)};"}
      data-role="preview-meeting"
      data-variant="pill"
    >
      <.meeting_icon name={@meeting.icon} colors={@colors} />
      <span class="truncate" data-role="preview-meeting-name">{@meeting.name}</span>
      <.meeting_duration meeting={@meeting} colors={@colors} />
    </p>
    """
  end

  def meeting_line(%{variant: :rule} = assigns) do
    ~H"""
    <p
      class="w-full min-w-0 flex items-center gap-2 text-token-xs font-semibold"
      style={"color: #{ink(@colors)};"}
      data-role="preview-meeting"
      data-variant="rule"
    >
      <span class="flex-1 h-px" style={"background: #{muted(@colors)}40;"} />
      <.meeting_icon name={@meeting.icon} colors={@colors} />
      <span class="truncate" data-role="preview-meeting-name">{@meeting.name}</span>
      <.meeting_duration meeting={@meeting} colors={@colors} />
      <span class="flex-1 h-px" style={"background: #{muted(@colors)}40;"} />
    </p>
    """
  end

  def meeting_line(%{variant: :plain} = assigns) do
    ~H"""
    <div
      class="w-full min-w-0 flex flex-col gap-0.5 text-left"
      data-role="preview-meeting"
      data-variant="plain"
    >
      <p
        class="text-token-xs font-semibold leading-snug line-clamp-2 break-words"
        style={"color: #{ink(@colors)};"}
        data-role="preview-meeting-name"
      >
        {@meeting.name}
      </p>
      <p class="flex items-center gap-1 text-token-2xs">
        <.meeting_icon name={@meeting.icon} colors={@colors} />
        <.meeting_duration meeting={@meeting} colors={@colors} />
      </p>
    </div>
    """
  end

  def meeting_line(assigns) do
    ~H"""
    <p
      class="w-full min-w-0 flex items-center gap-2 text-token-xs font-semibold text-left"
      style={"color: #{ink(@colors)};"}
      data-role="preview-meeting"
      data-variant="bar"
    >
      <span class="w-1 h-4 shrink-0 rounded-token-full" style={"background: #{primary(@colors)};"} />
      <span class="truncate" data-role="preview-meeting-name">{@meeting.name}</span>
      <.meeting_duration meeting={@meeting} colors={@colors} />
      <.meeting_icon name={@meeting.icon} colors={@colors} class="ml-auto" />
    </p>
    """
  end

  attr :meeting, :map, required: true
  attr :colors, :map, required: true

  defp meeting_duration(assigns) do
    ~H"""
    <span
      :if={@meeting.duration}
      class="shrink-0 font-medium whitespace-nowrap"
      style={"color: #{muted(@colors)};"}
      data-role="preview-meeting-duration"
    >
      {@meeting.duration}
    </span>
    """
  end

  attr :name, :string, required: true
  attr :colors, :map, required: true
  attr :class, :string, default: nil

  defp meeting_icon(assigns) do
    ~H"""
    <.icon
      name={@name}
      class={["w-3.5 h-3.5 shrink-0", @class]}
      style={"color: #{muted(@colors)};"}
      data-role="preview-meeting-icon"
      data-icon={@name}
    />
    """
  end

  # The theme's colours, or the neutral defaults where it sets none.
  defp primary(colors), do: PreviewParts.color(colors, :primary, "#14b8a6")
  defp ink(colors), do: PreviewParts.color(colors, :text, "#0f172a")
  defp muted(colors), do: PreviewParts.color(colors, :text_secondary, "#475569")
end
