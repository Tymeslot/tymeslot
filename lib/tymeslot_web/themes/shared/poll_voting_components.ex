defmodule TymeslotWeb.Themes.Shared.PollVotingComponents do
  @moduledoc """
  Shared, theme-neutral markup for the public poll voting page.

  These function components carry the structure and accessibility of the voting
  page; each theme wraps them in its own shell and styles the `poll-voting-*`
  classes via its own CSS module. All voter-facing strings use the `booking`
  gettext domain, matching `TymeslotWeb.Themes.Core.PollVoting`.

  The single entry point is `poll_content/1`, which decides which sub-view to
  render from the poll's status, the voting-open flag, and whether the page was
  opened through a participant's personal link. The sub-views
  (`identity_form/1`, `link_sent/1`, `invitation_only/1`, `slot_grid/1`,
  `poll_closed/1`, `deadline_banner/1`) are public so themes may compose them
  directly if they need a different arrangement.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Polls.PollParticipantSchema
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SecurityFields

  use TymeslotWeb.Components.CoreComponents, only: [honeypot_field: 1, icon: 1]

  @responses [:yes, :if_need_be, :no]

  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :voting_open, :boolean, required: true
  attr :participant, :map, default: nil
  attr :link_request, :atom, default: nil, values: [nil, :sent, :resent, :throttled]

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
          aria-label={dgettext("booking_polls", "Times shown in %{timezone}", timezone: tz(@poll))}
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
              {dgettext("booking_polls", "Voting has closed. Here are the final responses.")}
            </p>
            <.slot_grid
              poll={@poll}
              tallies={@tallies}
              participant={@participant}
              editable={false}
            />
          </div>
        <% :invite_only -> %>
          <.deadline_banner :if={@voting_open} poll={@poll} />
          <.invitation_only voting_open={@voting_open} />
        <% :register -> %>
          <.deadline_banner poll={@poll} />
          <%= if @link_request do %>
            <.link_sent outcome={@link_request} />
          <% else %>
            <.identity_form />
          <% end %>
          <.slot_grid poll={@poll} tallies={@tallies} editable={false} />
        <% :vote -> %>
          <.deadline_banner poll={@poll} />
          <p class="poll-voting-greeting" data-testid="poll-participant-name">
            {greeting(@participant)}
          </p>
          <p class="poll-voting-notice" data-testid="poll-link-notice">
            <%= if @participant.confirmed_at do %>
              {dgettext(
                "booking_polls",
                "This is your personal link. Please don't share it: anyone who has it can change your responses."
              )}
            <% else %>
              {dgettext(
                "booking_polls",
                "Save your responses to confirm your email address. They count from then on."
              )}
            <% end %>
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
      <span>{dgettext("booking_polls", "Voting closes %{deadline}", deadline: @deadline)}</span>
    </div>
    """
  end

  attr :outcome, :atom, required: true, values: [:sent, :resent, :throttled]

  @doc """
  Shown in place of the form once a voting link was requested. Says whether
  the address was new to the poll or already on it, and never repeats the
  address itself: the public page shows no addresses.
  """
  @spec link_sent(map()) :: Phoenix.LiveView.Rendered.t()
  def link_sent(assigns) do
    ~H"""
    <div class="poll-link-sent" role="status" data-testid="poll-link-sent" data-outcome={@outcome}>
      <.icon name="hero-envelope" class="poll-link-sent-icon" />
      <p class="poll-voting-notice">{link_sent_message(@outcome)}</p>
      <p :if={@outcome != :throttled} class="poll-voting-notice">
        {dgettext(
          "booking_polls",
          "Nothing there after a few minutes? Check your spam folder."
        )}
      </p>
    </div>
    """
  end

  @doc """
  Shown on an invite-only poll to anyone without a personal link: there is
  no form to ask for one, and the tallies are for the people invited.
  """
  attr :voting_open, :boolean, default: true

  @spec invitation_only(map()) :: Phoenix.LiveView.Rendered.t()
  def invitation_only(assigns) do
    ~H"""
    <div class="poll-invite-only" role="status" data-testid="poll-invite-only">
      <.icon name="hero-envelope" class="poll-invite-only-icon" />
      <p class="poll-voting-notice">
        <%= if @voting_open do %>
          {invite_only_message()}
        <% else %>
          {dgettext("booking_polls", "This poll is by invitation only, and voting has closed.")}
        <% end %>
      </p>
    </div>
    """
  end

  @doc "The notice for an invite-only poll, shared by the page and the flash."
  @spec invite_only_message() :: String.t()
  def invite_only_message do
    dgettext(
      "booking_polls",
      "This poll is by invitation only. Use the personal link from your email to vote."
    )
  end

  defp link_sent_message(:sent),
    do:
      dgettext(
        "booking_polls",
        "We've sent a personal voting link to the address you entered. Open it to vote; your responses count once you save them there."
      )

  defp link_sent_message(:resent),
    do:
      dgettext(
        "booking_polls",
        "This address is already on the poll; we've sent its voting link again."
      )

  defp link_sent_message(:throttled),
    do:
      dgettext(
        "booking_polls",
        "This address is already on the poll, and its voting link was sent a few minutes ago. Please check that inbox, including the spam folder."
      )

  @doc """
  Renders the name + email form that asks for a personal voting link.

  Submits `register_participant` to the dispatcher. Includes a honeypot field to
  catch automated submissions, matching the booking form.
  """
  @spec identity_form(map()) :: Phoenix.LiveView.Rendered.t()
  def identity_form(assigns) do
    # The token is verified with `RecaptchaHelpers.verify/3`, which pins the
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
      <p class="poll-voting-notice">
        {dgettext(
          "booking_polls",
          "Enter your name and email and we'll send you a personal link to vote with. Voted before? Enter the same email to get your link again."
        )}
      </p>

      <%!-- Honeypot: hidden from real users, tempting to bots. A non-empty
            value is silently rejected by the register handler. --%>
      <.honeypot_field id="poll-website" />

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
        <label class="poll-field-label" for="poll-name">{dgettext("booking_polls", "Your name")}</label>
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
        <label class="poll-field-label" for="poll-email">{dgettext("booking_polls", "Your email")}</label>
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
        {dgettext("booking_polls", "Email me my voting link")}
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
        <%!-- Someone the host invited by address alone gives their name with
              their first responses. --%>
        <div :if={@participant && is_nil(@participant.name)} class="poll-field">
          <label class="poll-field-label" for="poll-voter-name">
            {dgettext("booking_polls", "Your name")}
          </label>
          <input
            id="poll-voter-name"
            class="poll-field-input"
            type="text"
            name="name"
            autocomplete="name"
            required
            data-testid="poll-voter-name"
          />
        </div>
        <div class="poll-slot-grid">
          <.slot_row
            :for={slot <- @slots}
            slot={slot}
            tz={@tz}
            tally={Map.get(@tallies, slot.id, %{})}
            editable={true}
            current={Map.get(@current_votes, slot.id)}
            new?={new_to?(@participant, @current_votes, slot)}
          />
        </div>
        <button type="submit" class="poll-submit-button" data-testid="poll-save-votes">
          {dgettext("booking_polls", "Save my responses")}
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
          {dgettext("booking_polls", "Scheduled for %{time}", time: @scheduled)}
        <% else %>
          {dgettext("booking_polls", "This poll has been scheduled.")}
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
        {dgettext(
          "booking_polls",
          "This poll has been cancelled and is no longer accepting responses."
        )}
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
  attr :new?, :boolean, default: false

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
      <span class="poll-slot-time">
        {format_slot_time(@slot.start_time, @tz)}
        <span :if={@new?} class="poll-slot-new" data-testid="poll-slot-new">
          {dgettext("booking_polls", "New")}
        </span>
      </span>

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
  # Only a confirmed personal link votes on an invite-only poll. A pending
  # request's link (one that slipped in as the host switched) cannot confirm
  # (`Tymeslot.Polls.Voting.cast_votes/4`), so it gets the notice too. These
  # come before the deadline check so a bare link never shows the tallies
  # once voting has ended.
  defp voting_view(%{poll: %{invite_only: true}, participant: nil}), do: :invite_only

  defp voting_view(%{poll: %{invite_only: true}, participant: %{confirmed_at: nil}}),
    do: :invite_only

  defp voting_view(%{voting_open: false}), do: :voting_ended
  defp voting_view(%{participant: nil}), do: :register
  defp voting_view(_assigns), do: :vote

  # --- Data helpers ---

  # Someone invited by address alone has no name yet; the page greets them
  # without one rather than show their address.
  defp greeting(participant) do
    case PollParticipantSchema.public_name(participant) do
      nil -> dgettext("booking_polls", "You're voting with your personal link.")
      name -> dgettext("booking_polls", "Voting as %{name}", name: name)
    end
  end

  # A time is new to someone who has voted when the host added it after they
  # last saved their responses and they have not answered it since. A time
  # they left unanswered when they voted was there to answer, so it is not new.
  defp new_to?(%{voted_at: %DateTime{} = voted_at}, current_votes, slot) do
    not Map.has_key?(current_votes, slot.id) and
      DateTime.compare(slot.inserted_at, voted_at) == :gt
  end

  defp new_to?(_participant, _current_votes, _slot), do: false

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

  defp tally_label(:yes), do: dgettext("booking_polls", "Yes")
  defp tally_label(:if_need_be), do: dgettext("booking_polls", "If need be")
  defp tally_label(:no), do: dgettext("booking_polls", "No")
end
