defmodule TymeslotWeb.Themes.Shared.PollVotingComponents do
  @moduledoc """
  Shared, theme-neutral markup for the public poll voting page.

  These function components carry the structure and accessibility of the voting
  page; each theme wraps them in its own shell and styles the `poll-voting-*`
  classes via its own CSS module. All voter-facing strings use the `booking`
  gettext domain, matching `TymeslotWeb.Themes.Core.PollVoting`.

  The single entry point is `poll_content/1`, which decides which sub-view to
  render from the poll's status, the voting-open flag, and whether a participant
  is registered. The sub-views (`identity_form/1`, `slot_grid/1`,
  `poll_closed/1`, `deadline_banner/1`) are public so themes may compose them
  directly if they need a different arrangement.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SecurityFields

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @responses [:yes, :if_need_be, :no]

  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :voting_open, :boolean, required: true
  attr :participant, :map, default: nil

  @doc """
  Renders the whole voting page body, choosing the right view from poll state.
  """
  @spec poll_content(map()) :: Phoenix.LiveView.Rendered.t()
  def poll_content(assigns) do
    assigns = assign(assigns, :view, voting_view(assigns))

    ~H"""
    <div class="poll-voting" data-testid="poll-voting">
      <div class="poll-voting-header">
        <h1 class="poll-voting-title" data-testid="poll-title">{@poll.title}</h1>
        <p :if={@poll.description && @poll.description != ""} class="poll-voting-description">
          {@poll.description}
        </p>
        <%!-- Slot rows show a compact date with no zone on it, so the zone has
              to be stated once here or every candidate time is unlabelled. It
              reads as a property of the poll rather than a sentence about it,
              so it is a badge; the full phrasing stays on the label, which
              keeps the accessible reading intact. --%>
        <p
          class="poll-voting-timezone"
          data-testid="poll-timezone"
          aria-label={dgettext("booking", "Times shown in %{timezone}", timezone: tz(@poll))}
        >
          <.icon name="hero-globe-alt" class="poll-voting-timezone-icon" />
          <span>{tz(@poll)}</span>
        </p>
      </div>

      <%= case @view do %>
        <% :closed -> %>
          <.poll_closed poll={@poll} tallies={@tallies} />
        <% :voting_ended -> %>
          <div class="poll-voting-ended" data-testid="poll-voting-ended">
            <p class="poll-voting-notice">
              {dgettext("booking", "Voting has closed. Here are the final responses.")}
            </p>
            <.slot_grid
              poll={@poll}
              tallies={@tallies}
              participant={@participant}
              editable={false}
            />
          </div>
        <% :register -> %>
          <.deadline_banner poll={@poll} />
          <.identity_form />
          <.slot_grid poll={@poll} tallies={@tallies} editable={false} />
        <% :vote -> %>
          <.deadline_banner poll={@poll} />
          <p class="poll-voting-greeting" data-testid="poll-participant-name">
            {dgettext("booking", "Voting as %{name}", name: @participant.name)}
          </p>
          <.slot_grid
            poll={@poll}
            tallies={@tallies}
            participant={@participant}
            editable={true}
          />
      <% end %>
    </div>
    """
  end

  attr :poll, :map, required: true

  @doc "Shows the voting deadline when the poll has one."
  @spec deadline_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def deadline_banner(%{poll: %{deadline_at: nil}} = assigns), do: ~H""

  def deadline_banner(assigns) do
    assigns =
      assign(assigns, :deadline, format_datetime(assigns.poll.deadline_at, tz(assigns.poll)))

    ~H"""
    <div class="poll-deadline-banner" data-testid="poll-deadline">
      <.icon name="hero-clock" class="poll-deadline-icon" />
      <span>{dgettext("booking", "Voting closes %{deadline}", deadline: @deadline)}</span>
    </div>
    """
  end

  @doc """
  Renders the name + email registration form.

  Submits `register_participant` to the dispatcher. Includes a honeypot field to
  catch automated submissions, matching the booking form.
  """
  @spec identity_form(map()) :: Phoenix.LiveView.Rendered.t()
  def identity_form(assigns) do
    # The token is verified with `maybe_verify_booking_token/2`, which pins the
    # expected action to `booking_action/0`. Sending anything else here fails
    # verification with `recaptcha_action_mismatch`, so the action must be read
    # from the same place the verifier reads it.
    assigns =
      assign(
        assigns,
        :recaptcha_attrs,
        SecurityFields.recaptcha_form_attrs(RecaptchaHelpers.booking_action(), "poll")
      )

    ~H"""
    <%!-- The id is load-bearing: phx-hook is ignored without one, and the
          RecaptchaV3 hook is what fills the token field before submit. --%>
    <form
      id="poll-register-form"
      phx-submit="register_participant"
      class="poll-identity-form"
      data-testid="poll-register-form"
      {@recaptcha_attrs}
    >
      <%!-- Honeypot: hidden from real users, tempting to bots. A non-empty
            value is silently rejected by the register handler. --%>
      <div class="honeypot-field" aria-hidden="true">
        <label for="poll-website">Website</label>
        <input
          id="poll-website"
          type="text"
          name="website"
          tabindex="-1"
          autocomplete="off"
          value=""
        />
      </div>

      <%!-- The RecaptchaV3 hook finds this by id when the form posts flat
            params rather than a nested param root. Rendered only when booking
            reCAPTCHA is configured; the server verifies it either way. --%>
      <input
        :if={RecaptchaHelpers.booking_active?()}
        type="hidden"
        id="g-recaptcha-response"
        name="g-recaptcha-response"
        value=""
      />

      <div class="poll-field">
        <label class="poll-field-label" for="poll-name">{dgettext("booking", "Your name")}</label>
        <input
          id="poll-name"
          class="poll-field-input"
          type="text"
          name="name"
          autocomplete="name"
          required
          data-testid="poll-name"
        />
      </div>

      <div class="poll-field">
        <label class="poll-field-label" for="poll-email">{dgettext("booking", "Your email")}</label>
        <input
          id="poll-email"
          class="poll-field-input"
          type="email"
          name="email"
          autocomplete="email"
          required
          data-testid="poll-email"
        />
      </div>

      <button type="submit" class="poll-submit-button" data-testid="poll-register-submit">
        {dgettext("booking", "Continue to vote")}
      </button>

      <SecurityFields.recaptcha_notice_block />
    </form>
    """
  end

  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :participant, :map, default: nil
  attr :editable, :boolean, default: false

  @doc """
  Renders the candidate slots with their running tallies.

  When `editable` is true a form wraps the grid and the participant's row exposes
  three-state (yes / if-need-be / no) radio controls, pre-selected from their
  saved responses; the whole grid submits via `cast_votes`.
  """
  @spec slot_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def slot_grid(assigns) do
    assigns =
      assigns
      |> assign(:slots, assigns.poll.time_slots)
      |> assign(:tz, tz(assigns.poll))
      |> assign(:current_votes, participant_votes(assigns.participant))

    ~H"""
    <%= if @editable do %>
      <form phx-submit="cast_votes" class="poll-slot-form" data-testid="poll-vote-form">
        <div class="poll-slot-grid">
          <.slot_row
            :for={slot <- @slots}
            slot={slot}
            tz={@tz}
            tally={Map.get(@tallies, slot.id, %{})}
            editable={true}
            current={Map.get(@current_votes, slot.id)}
          />
        </div>
        <button type="submit" class="poll-submit-button" data-testid="poll-save-votes">
          {dgettext("booking", "Save my responses")}
        </button>
      </form>
    <% else %>
      <div class="poll-slot-grid" data-testid="poll-slot-grid">
        <.slot_row
          :for={slot <- @slots}
          slot={slot}
          tz={@tz}
          tally={Map.get(@tallies, slot.id, %{})}
          editable={false}
        />
      </div>
    <% end %>
    """
  end

  @doc """
  Renders the closed-poll view: a confirmed schedule or a cancellation notice.
  """
  @spec poll_closed(map()) :: Phoenix.LiveView.Rendered.t()
  def poll_closed(%{poll: %{status: :confirmed}} = assigns) do
    assigns = assign(assigns, :scheduled, scheduled_time(assigns.poll))

    ~H"""
    <div class="poll-closed poll-closed--confirmed" data-testid="poll-confirmed">
      <.icon name="hero-check-circle" class="poll-closed-icon poll-closed-icon--success" />
      <p class="poll-closed-message">
        <%= if @scheduled do %>
          {dgettext("booking", "Scheduled for %{time}", time: @scheduled)}
        <% else %>
          {dgettext("booking", "This poll has been scheduled.")}
        <% end %>
      </p>
    </div>
    """
  end

  def poll_closed(assigns) do
    ~H"""
    <div class="poll-closed poll-closed--cancelled" data-testid="poll-cancelled">
      <.icon name="hero-x-circle" class="poll-closed-icon poll-closed-icon--danger" />
      <p class="poll-closed-message">
        {dgettext("booking", "This poll has been cancelled and is no longer accepting responses.")}
      </p>
    </div>
    """
  end

  # --- Slot row ---

  attr :slot, :map, required: true
  attr :tz, :string, required: true
  attr :tally, :map, required: true
  attr :editable, :boolean, required: true
  attr :current, :atom, default: nil

  defp slot_row(assigns) do
    ~H"""
    <%!-- A plain div, not a fieldset. A <legend> is taken out of the fieldset's
          flow and painted over its top border, so keeping the time inside the
          box meant forcing it onto a line of its own, which cost about a third
          of each row's height. The vote controls already declare
          role="radiogroup" labelled by the same time, so the fieldset was
          contributing no grouping the assistive tree did not already have.
          Time, tallies and controls now share one line and wrap only when the
          card is too narrow to hold them. --%>
    <div class="poll-slot-row" data-testid="poll-slot">
      <span class="poll-slot-time">{format_slot_time(@slot.start_time, @tz)}</span>

      <div class="poll-slot-tallies">
        <span :for={response <- responses()} class={"poll-tally poll-tally--#{response}"}>
          <%!-- Label first so the accessible reading is "Yes: 2", not "2 Yes". --%>
          <span class="sr-only">{tally_label(response)}:</span>
          <.icon name={tally_icon(response)} class="poll-tally-icon" />
          <span class="poll-tally-count">{Map.get(@tally, response, 0)}</span>
        </span>
      </div>

      <div
        :if={@editable}
        class="poll-vote-controls"
        role="radiogroup"
        aria-label={format_datetime(@slot.start_time, @tz)}
      >
        <label
          :for={response <- responses()}
          class={"poll-vote-option poll-vote-option--#{response}"}
        >
          <input
            type="radio"
            name={"votes[#{@slot.id}]"}
            value={to_string(response)}
            checked={@current == response}
            data-testid={"vote-#{@slot.id}-#{response}"}
          />
          <span class="poll-vote-option-label">{tally_label(response)}</span>
        </label>
      </div>
    </div>
    """
  end

  # --- View selection ---

  defp voting_view(%{poll: %{status: :cancelled}}), do: :closed
  defp voting_view(%{poll: %{status: :confirmed}}), do: :closed
  defp voting_view(%{voting_open: false}), do: :voting_ended
  defp voting_view(%{participant: nil}), do: :register
  defp voting_view(_assigns), do: :vote

  # --- Data helpers ---

  defp responses, do: @responses

  defp participant_votes(nil), do: %{}

  defp participant_votes(%{votes: votes}) when is_list(votes) do
    Map.new(votes, fn vote -> {vote.poll_time_slot_id, vote.response} end)
  end

  defp participant_votes(_participant), do: %{}

  defp scheduled_time(%{confirmed_meeting: %{start_time: %DateTime{} = start_time}} = poll) do
    format_datetime(start_time, tz(poll))
  end

  defp scheduled_time(_poll), do: nil

  defp tz(%{timezone: timezone}) when is_binary(timezone) and timezone != "", do: timezone
  defp tz(_poll), do: "Etc/UTC"

  defp format_datetime(datetime, timezone) do
    LocalizationHelpers.format_meeting_datetime(datetime, timezone)
  end

  # Slot rows repeat the date on every line, so they drop the year and zone
  # that `format_datetime/2` carries; `poll-voting-timezone` states the zone
  # once for the whole list instead. The radiogroup label keeps the full form,
  # since a screen reader reads one slot at a time with no such header nearby.
  defp format_slot_time(datetime, timezone) do
    LocalizationHelpers.format_meeting_datetime_compact(datetime, timezone)
  end

  # --- Response presentation ---

  defp tally_icon(:yes), do: "hero-check-circle-solid"
  defp tally_icon(:if_need_be), do: "hero-question-mark-circle-solid"
  defp tally_icon(:no), do: "hero-x-circle-solid"

  defp tally_label(:yes), do: dgettext("booking", "Yes")
  defp tally_label(:if_need_be), do: dgettext("booking", "If need be")
  defp tally_label(:no), do: dgettext("booking", "No")
end
