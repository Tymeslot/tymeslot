defmodule TymeslotWeb.Components.Dashboard.Appointments.JoinLink do
  @moduledoc """
  The Join meeting link, and the live countdown that reveals it as an
  appointment approaches.

  The countdown is a `<time>` driven by the `AgendaCountdown` JS hook
  (`assets/js/hooks/agenda_countdown.js`), which ticks the text client-side
  from the translated templates in `data-tpl-*` and toggles `hidden` on the
  element named by `data-join`, from ten minutes before the start until the
  end. `agenda_countdown/1` renders the pair together so the two ids can never
  disagree.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.DashboardOverviewFormatters

  attr :url, :string, required: true
  attr :variant, :atom, default: :primary, values: [:primary, :secondary, :on_dark]
  attr :size, :atom, default: :md, values: [:sm, :md]
  attr :id, :string, default: nil

  attr :hidden, :boolean,
    default: false,
    doc: "Render hidden, for the countdown hook to reveal near the start"

  attr :class, :any, default: nil, doc: "Layout classes only"

  @doc """
  A link that opens the meeting's video call in a new tab.

  The no-op `phx-click` keeps a click on the link from also reaching a
  clickable row or card around it, which would open its detail modal.
  """
  @spec join_link(map()) :: Phoenix.LiveView.Rendered.t()
  def join_link(assigns) do
    ~H"""
    <CoreComponents.action_link
      id={@id}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      phx-click={%JS{}}
      variant={@variant}
      size={@size}
      icon={if @size == :sm, do: "hero-video-camera-mini", else: "hero-video-camera"}
      class={[@hidden && "hidden", @class]}
    >
      {dgettext("dashboard_common", "Join meeting")}
    </CoreComponents.action_link>
    """
  end

  attr :entry, Entry, required: true

  attr :id_prefix, :string,
    required: true,
    doc: "Names the surface, so two countdowns for one entry on a page keep distinct ids"

  attr :class, :any, default: nil, doc: "Classes for the countdown text"

  @doc """
  The live countdown to `entry`'s start, followed by its Join link (when it has
  one), hidden until the hook reveals it.

  The countdown's id carries the start time: `phx-update="ignore"` hands the
  element to the hook and stops LiveView patching it after mount, so a
  reschedule under the same entry id would otherwise keep counting toward the
  old time. A changed start makes a new id, and the hook remounts.
  """
  @spec agenda_countdown(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_countdown(assigns) do
    assigns =
      assign(assigns,
        join_id: "#{assigns.id_prefix}-join-#{assigns.entry.id}",
        templates: DashboardOverviewFormatters.countdown_templates()
      )

    ~H"""
    <time
      id={"#{@id_prefix}-countdown-#{@entry.id}-#{DateTime.to_unix(@entry.start_at)}"}
      phx-hook="AgendaCountdown"
      phx-update="ignore"
      data-start={DateTime.to_iso8601(@entry.start_at)}
      data-end={DateTime.to_iso8601(@entry.end_at)}
      data-join={@entry.join_url && @join_id}
      data-tpl-now={@templates.now}
      data-tpl-minutes={@templates.minutes}
      data-tpl-hours={@templates.hours}
      data-tpl-days={@templates.days}
      class={["font-black tabular-nums leading-none", @class]}
    >{DashboardOverviewFormatters.relative_hint(@entry)}</time>
    <.join_link
      :if={@entry.join_url}
      id={@join_id}
      url={@entry.join_url}
      variant={:on_dark}
      size={:sm}
      hidden
      class="shrink-0"
    />
    """
  end
end
