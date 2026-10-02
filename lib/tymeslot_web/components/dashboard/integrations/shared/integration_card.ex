defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard do
  @moduledoc """
  The one card every connected integration renders as: calendar and video
  connections, the automation channels (webhooks, Slack, Telegram) and the
  Stripe account behind payments.

  Top to bottom:

    * a header with a status-tinted icon tile, the title (plus an optional type
      tag) and its status pill, a one-line summary, and the on/off switch
      pinned to the top-right corner;
    * optional details: event tags, a last-activity line and a notice saying
      what needs the owner's attention;
    * a footer action bar, `:actions` on the left and `:end_actions` (edit,
      delete and the like) pushed to the right.

  On a phone the switch stays in the header beside the title instead of
  dropping onto its own line, the pill wraps under a long title, the summary
  wraps instead of being cut off (it truncates from `sm` up, with the full text
  as its hover title), and the footer wraps as a row rather than stacking.

  The card is stateless: the switch pushes `toggle_event` with
  `phx-value-id={@id}` to `target`, and every action is the caller's own
  markup.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.UI.StatusSwitch

  # The icon tile carries the status colour, so a card reads at a glance even
  # before the pill is read.
  @tile_classes %{
    brand: "bg-turquoise-50 text-turquoise-600",
    success: "bg-turquoise-50 text-turquoise-600",
    warning: "bg-amber-50 text-amber-600",
    danger: "bg-red-50 text-red-500",
    info: "bg-blue-50 text-blue-600",
    neutral: "bg-tymeslot-100 text-tymeslot-400"
  }

  @notice_classes %{warning: "text-amber-700", danger: "text-red-600"}

  attr :id, :string, required: true, doc: "The record's id, sent with the toggle as `id`"
  attr :title, :string, required: true
  attr :status, :any, required: true, doc: "`{tone, label}`, `tone` being a `pill/1` tone"
  attr :pulse, :boolean, default: false, doc: "Animate the status dot (an awaited step)"
  attr :type_tag, :string, default: nil, doc: "A short descriptor shown beside the title"
  attr :summary, :string, default: nil
  attr :summary_mono, :boolean, default: false, doc: "Set the summary in monospace (URLs, ids)"
  attr :active, :boolean, default: true, doc: "The switch's state; false de-emphasises the card"

  attr :toggle_event, :string,
    default: nil,
    doc: "The event the switch pushes; no switch is shown without one"

  attr :toggle_id, :string, default: nil, doc: "The switch's DOM id; defaults to `toggle-<id>`"
  attr :target, :any, default: nil
  attr :tags, :list, default: [], doc: "Event names shown as chips"
  attr :notice, :string, default: nil, doc: "What needs the owner's attention"
  attr :notice_tone, :atom, default: :warning, values: [:warning, :danger]
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global

  slot :icon, required: true, doc: "The provider's icon, sized to fit a 44px tile"

  slot :last_activity, doc: "When it last did something; shown after a clock icon" do
    attr :muted, :boolean, doc: "Grey italics, for a never-used integration"
  end

  slot :actions, doc: "The footer's leading actions"
  slot :end_actions, doc: "The footer's trailing actions, pushed to the right"

  @spec integration_card(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_card(assigns) do
    {tone, label} = assigns.status

    assigns =
      assign(assigns,
        tone: tone,
        status_label: label,
        tile_class: Map.fetch!(@tile_classes, tone),
        notice_class: Map.fetch!(@notice_classes, assigns.notice_tone),
        toggle_id: assigns.toggle_id || "toggle-#{assigns.id}",
        summary: present(assigns.summary),
        footer?: assigns.actions != [] or assigns.end_actions != []
      )

    ~H"""
    <div
      class={["card-glass p-4 sm:p-5 transition-opacity", !@active && "opacity-70", @class]}
      {@rest}
    >
      <div class="flex items-start gap-3 sm:gap-4">
        <div class={[
          "flex h-11 w-11 shrink-0 items-center justify-center rounded-token-xl",
          @tile_class
        ]}>
          {render_slot(@icon)}
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <h3 class="min-w-0 break-words text-token-base font-semibold text-tymeslot-900">
              {@title}
            </h3>
            <span
              :if={@type_tag}
              class="rounded-token-sm bg-tymeslot-100 px-1.5 py-0.5 text-token-xs font-semibold uppercase text-tymeslot-500"
            >
              {@type_tag}
            </span>
            <.pill tone={@tone} dot pulse={@pulse}>{@status_label}</.pill>
          </div>
          <p
            :if={@summary}
            title={@summary}
            class={[
              "mt-0.5 break-words text-token-sm text-tymeslot-500 sm:truncate",
              @summary_mono && "font-mono"
            ]}
          >
            {@summary}
          </p>
        </div>

        <StatusSwitch.status_switch
          :if={@toggle_event}
          id={@toggle_id}
          checked={@active}
          on_change={@toggle_event}
          target={@target}
          phx_value_id={@id}
          aria_label={@title}
          class="shrink-0"
        />
      </div>

      <div :if={@tags != []} class="mt-3 flex flex-wrap gap-1.5">
        <span
          :for={tag <- @tags}
          class={[
            "inline-flex items-center gap-1.5 rounded-token-lg border px-2 py-0.5 text-token-xs font-bold",
            (@active && "border-turquoise-200 bg-turquoise-50 text-turquoise-700") ||
              "border-tymeslot-200 bg-tymeslot-100 text-tymeslot-500"
          ]}
        >
          <span
            class={[
              "h-1.5 w-1.5 rounded-token-full",
              (@active && "bg-turquoise-500") || "bg-tymeslot-400"
            ]}
            aria-hidden="true"
          ></span>
          {tag}
        </span>
      </div>

      <div
        :for={activity <- @last_activity}
        class={[
          "mt-3 flex items-center gap-2 text-token-sm",
          (activity[:muted] && "italic text-tymeslot-400") || "text-tymeslot-500"
        ]}
      >
        <.icon name="hero-clock" class="h-4 w-4 shrink-0" />
        <span class="min-w-0">{render_slot(activity)}</span>
      </div>

      <p :if={@notice} class={["mt-2 text-token-sm font-medium", @notice_class]}>{@notice}</p>

      <div
        :if={@footer?}
        class="mt-4 flex flex-wrap items-center gap-2 border-t border-tymeslot-100 pt-3"
      >
        {render_slot(@actions)}
        <div :if={@end_actions != []} class="ml-auto flex items-center gap-2">
          {render_slot(@end_actions)}
        </div>
      </div>
    </div>
    """
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(text) when is_binary(text), do: text
end
