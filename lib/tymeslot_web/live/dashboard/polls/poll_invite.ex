defmodule TymeslotWeb.Dashboard.Polls.PollInvite do
  @moduledoc """
  Inviting people to a poll by email, shared by the create form and the
  results panel of an open poll.

  Holds the address field, the "waiting for" line that names whoever has not
  voted yet, and the wording of what an invitation did or why it failed, so
  that both surfaces read the same. The invitations themselves are
  `Tymeslot.Polls.Invitations`.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls.{Invitations, PollParticipantSchema, PollSchema}
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Forms

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :errors, :list, default: []

  @doc "The address field, with how to fill it in."
  @spec invitees_input(map()) :: Phoenix.LiveView.Rendered.t()
  def invitees_input(assigns) do
    ~H"""
    <div data-testid="poll-invitees">
      <Forms.input
        type="textarea"
        name={@name}
        label={dgettext("dashboard_polls", "Invite by email (optional)")}
        value={@value}
        placeholder={dgettext("dashboard_polls", "ada@example.com, Grace Hopper <grace@example.com>")}
        errors={@errors}
      />
      <p class="text-token-xs text-tymeslot-500 mt-1">
        {dgettext(
          "dashboard_polls",
          "One address per line or separated by commas. Each person gets an email with their own voting link."
        )}
      </p>
    </div>
    """
  end

  attr :poll, :map, required: true
  attr :value, :string, default: ""
  attr :error, :string, default: nil
  attr :myself, :any, required: true

  @doc "Invites more people to an open poll, from its results panel."
  @spec invite_form(map()) :: Phoenix.LiveView.Rendered.t()
  def invite_form(assigns) do
    ~H"""
    <form
      id={"poll-invite-form-#{@poll.id}"}
      phx-submit="invite_participants"
      phx-target={@myself}
      class="space-y-3 pt-2 border-t border-tymeslot-100"
      data-testid="poll-invite-form"
      novalidate
    >
      <.invitees_input name="invite[emails]" value={@value} errors={List.wrap(@error)} />
      <div class="flex justify-end">
        <Buttons.action_button type="submit" size={:sm} icon="hero-envelope">
          {dgettext("dashboard_polls", "Send invitations")}
        </Buttons.action_button>
      </div>
    </form>
    """
  end

  attr :participants, :list, required: true

  @doc "Names whoever on the poll has not voted yet, invitees mostly."
  @spec waiting_for(map()) :: Phoenix.LiveView.Rendered.t()
  def waiting_for(assigns) do
    assigns =
      assign(
        assigns,
        :names,
        for(
          p <- assigns.participants,
          is_nil(p.voted_at),
          do: PollParticipantSchema.display_name(p)
        )
      )

    ~H"""
    <p :if={@names != []} class="text-token-xs text-tymeslot-500" data-testid="poll-waiting-for">
      {dgettext("dashboard_polls", "Waiting for: %{names}", names: Enum.join(@names, ", "))}
    </p>
    """
  end

  @doc "What an invitation did, for the flash."
  @spec invited_message(Invitations.result()) :: String.t()
  def invited_message(%{invited: invited, skipped: skipped}) do
    sent =
      dngettext(
        "dashboard_polls",
        "Invitation sent to %{count} person.",
        "Invitations sent to %{count} people.",
        length(invited)
      )

    case skipped do
      [] ->
        sent

      _skipped ->
        sent <>
          " " <>
          dngettext(
            "dashboard_polls",
            "%{count} address was already on the poll.",
            "%{count} addresses were already on the poll.",
            length(skipped)
          )
    end
  end

  @doc "Why an invitation failed, for the address field."
  @spec error_message(term()) :: String.t()
  def error_message({:invalid_addresses, entries}),
    do:
      dgettext("dashboard_polls", "Not valid email addresses: %{entries}",
        entries: Enum.join(entries, ", ")
      )

  def error_message(reason) when reason in [:too_many_invitees, :poll_full],
    do:
      dgettext("dashboard_polls", "A poll can have up to %{max} participants.",
        max: PollSchema.max_participants()
      )

  def error_message(:no_invitees),
    do: dgettext("dashboard_polls", "Enter at least one email address.")

  def error_message(:not_open), do: dgettext("dashboard_polls", "This poll is no longer open.")

  def error_message(_reason),
    do: dgettext("dashboard_polls", "Couldn't send the invitations. Please try again.")
end
