defmodule TymeslotWeb.Dashboard.Polls.PollAccess do
  @moduledoc """
  Who can vote on a poll, as the dashboard asks and shows it: anyone the host
  shares the poll's link with, or only the people they invite by email
  (`invite_only` on `Tymeslot.Polls.PollSchema`). Shared by the create form,
  the poll editor and the results panel, so the three read the same.

  The choice travels as `"anyone"` or `"invited"`, the values of its radio
  buttons, inside the caller's form.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls
  alias Tymeslot.Polls.Invitations
  alias TymeslotWeb.Components.CoreComponents.Feedback

  @doc "The form value for whether a poll is invite-only."
  @spec value(boolean()) :: String.t()
  def value(true), do: "invited"
  def value(false), do: "anyone"

  @doc "Whether a submitted form value makes the poll invite-only. Anything unknown is not."
  @spec invite_only?(term()) :: boolean()
  def invite_only?("invited"), do: true
  def invite_only?(_value), do: false

  @doc """
  The create form's choice once `params` arrive, and whether the host made
  it: their choice, or until they make one, the default for the invitees
  typed so far. The form always sends whichever radio is checked, and a
  change event can carry the value the page showed before the server's
  default flipped, so only a change the radio itself triggered (`target`)
  is a choice. A submit (no target) keeps the host's choice, or else the
  default. `assigns` are the form's, with `:access`, `:access_chosen?` and
  `:invitees`.
  """
  @spec resolve(map(), [String.t()] | nil, map()) :: {String.t(), boolean()}
  def resolve(%{"access" => value}, ["poll", "access"], _assigns)
      when value in ["anyone", "invited"],
      do: {value, true}

  def resolve(_params, _target, %{access: shown, access_chosen?: true}), do: {shown, true}

  def resolve(params, _target, assigns),
    do: {default(Map.get(params, "invitees", assigns.invitees)), false}

  # An unreadable list is still a list of people the host means to invite.
  defp default(invitees_text) do
    case Invitations.parse(invitees_text) do
      {:ok, invitees} -> value(Polls.default_invite_only?(invitees))
      {:error, _reason} -> value(true)
    end
  end

  @doc "The create form's warning for `access` with the invitees typed so far."
  @spec create_hint(String.t(), String.t() | nil) :: String.t() | nil
  def create_hint("invited", invitees) do
    if String.trim(invitees || "") == "" do
      dgettext(
        "dashboard_polls",
        "Nobody can vote until you invite someone. You can also invite people after creating the poll."
      )
    end
  end

  def create_hint(_access, _invitees), do: nil

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil, doc: "a warning about the current choice, if any"

  @doc """
  The two choices as radio buttons. A plain fieldset rather than
  `Forms.input`, which renders one input under a block label; the radios
  carry a description each and post with the rest of the form.
  """
  @spec access_input(map()) :: Phoenix.LiveView.Rendered.t()
  def access_input(assigns) do
    ~H"""
    <fieldset
      class="space-y-2"
      data-testid="poll-access"
      aria-describedby={@hint && "#{@id}-hint"}
    >
      <legend class="label mb-1">{dgettext("dashboard_polls", "Who can vote")}</legend>

      <div class="flex items-start gap-2 text-token-sm">
        <%!-- raw-input: native radio beside its label and description block; <.input> gives a radio text-field styling and drops checked --%>
        <input
          type="radio"
          id={"#{@id}-anyone"}
          name={@name}
          value="anyone"
          checked={@value == "anyone"}
          aria-describedby={"#{@id}-anyone-description"}
          class="mt-1"
        />
        <div>
          <label class="font-medium text-tymeslot-800" for={"#{@id}-anyone"}>
            {dgettext("dashboard_polls", "Anyone with the link")}
          </label>
          <span
            id={"#{@id}-anyone-description"}
            class="block text-token-xs text-tymeslot-500"
          >
            {dgettext(
              "dashboard_polls",
              "Anyone you share the poll's link with can ask for a personal voting link by email."
            )}
          </span>
        </div>
      </div>

      <div class="flex items-start gap-2 text-token-sm">
        <%!-- raw-input: native radio beside its label and description block; <.input> gives a radio text-field styling and drops checked --%>
        <input
          type="radio"
          id={"#{@id}-invited"}
          name={@name}
          value="invited"
          checked={@value == "invited"}
          aria-describedby={"#{@id}-invited-description"}
          class="mt-1"
        />
        <div>
          <label class="font-medium text-tymeslot-800" for={"#{@id}-invited"}>
            {dgettext("dashboard_polls", "Only people I invite")}
          </label>
          <span
            id={"#{@id}-invited-description"}
            class="block text-token-xs text-tymeslot-500"
          >
            {dgettext(
              "dashboard_polls",
              "Only the people you invite by email can vote. Anyone else who opens the link is told the poll is by invitation."
            )}
          </span>
        </div>
      </div>

      <p
        :if={@hint}
        id={"#{@id}-hint"}
        aria-live="polite"
        class="text-token-xs text-amber-700"
        data-testid="poll-access-hint"
      >
        {@hint}
      </p>
    </fieldset>
    """
  end

  attr :poll, :map, required: true

  @doc "Names who can vote on `poll`, for the results panel."
  @spec access_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def access_pill(assigns) do
    ~H"""
    <Feedback.pill
      :if={@poll.invite_only}
      icon="hero-envelope-mini"
      data-testid="poll-access-mode"
    >
      {dgettext("dashboard_polls", "Only invited people")}
    </Feedback.pill>
    <Feedback.pill :if={!@poll.invite_only} icon="hero-link-mini" data-testid="poll-access-mode">
      {dgettext("dashboard_polls", "Anyone with the link")}
    </Feedback.pill>
    """
  end
end
