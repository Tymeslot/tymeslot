defmodule TymeslotWeb.Dashboard.Polls.PollFormActions do
  @moduledoc """
  The buttons under the poll create form (`PollForm`): cancel, save as a
  draft, and create the poll, or for a draft already saved, publish it, with
  a way to delete the draft.

  Both submit buttons sit outside the form, so the reminder picker can come
  before them; `form` ties them back to it, and each sends `intent`, which
  the form reads to choose between saving and publishing.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Buttons

  attr :form, :string, required: true, doc: "The id of the form the submit buttons send"
  attr :draft?, :boolean, required: true
  attr :parent_myself, :any, required: true

  @doc "Renders the form's buttons."
  @spec actions(map()) :: Phoenix.LiveView.Rendered.t()
  def actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-end gap-3 pt-2">
      <Buttons.action_button
        :if={@draft?}
        variant={:danger}
        icon="hero-trash"
        phx-click="request_delete_poll"
        phx-target={@parent_myself}
        class="sm:mr-auto"
        data-testid="delete-draft"
      >
        {dgettext("dashboard_polls", "Delete draft")}
      </Buttons.action_button>
      <Buttons.action_button
        variant={:secondary}
        phx-click="cancel_poll_form"
        phx-target={@parent_myself}
      >
        {dgettext("dashboard_polls", "Cancel")}
      </Buttons.action_button>
      <Buttons.action_button
        variant={:secondary}
        type="submit"
        form={@form}
        name="intent"
        value="draft"
        data-testid="save-draft"
      >
        {dgettext("dashboard_polls", "Save draft")}
      </Buttons.action_button>
      <Buttons.action_button
        type="submit"
        form={@form}
        name="intent"
        value="publish"
        data-testid="publish-poll"
      >
        {if @draft?,
          do: dgettext("dashboard_polls", "Publish poll"),
          else: dgettext("dashboard_polls", "Create poll")}
      </Buttons.action_button>
    </div>
    """
  end
end
