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

  alias TymeslotWeb.Components.CoreComponents.Feedback

  @doc "The form value for whether a poll is invite-only."
  @spec value(boolean()) :: String.t()
  def value(true), do: "invited"
  def value(false), do: "anyone"

  @doc "Whether a submitted form value makes the poll invite-only. Anything unknown is not."
  @spec invite_only?(term()) :: boolean()
  def invite_only?("invited"), do: true
  def invite_only?(_value), do: false

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
    <fieldset class="space-y-2" data-testid="poll-access">
      <legend class="label mb-1">{dgettext("dashboard_polls", "Who can vote")}</legend>

      <label class="flex items-start gap-2 text-token-sm" for={"#{@id}-anyone"}>
        <input
          type="radio"
          id={"#{@id}-anyone"}
          name={@name}
          value="anyone"
          checked={@value == "anyone"}
          class="mt-1"
        />
        <span>
          <span class="font-medium text-tymeslot-800">
            {dgettext("dashboard_polls", "Anyone with the link")}
          </span>
          <span class="block text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_polls",
              "Anyone you share the poll's link with can ask for a personal voting link by email."
            )}
          </span>
        </span>
      </label>

      <label class="flex items-start gap-2 text-token-sm" for={"#{@id}-invited"}>
        <input
          type="radio"
          id={"#{@id}-invited"}
          name={@name}
          value="invited"
          checked={@value == "invited"}
          class="mt-1"
        />
        <span>
          <span class="font-medium text-tymeslot-800">
            {dgettext("dashboard_polls", "Only people I invite")}
          </span>
          <span class="block text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_polls",
              "Only the people you invite by email can vote. Anyone else who opens the link is told the poll is by invitation."
            )}
          </span>
        </span>
      </label>

      <p
        :if={@hint}
        class="flex items-center gap-1 text-token-xs text-amber-700"
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
