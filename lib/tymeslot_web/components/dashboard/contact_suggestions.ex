defmodule TymeslotWeb.Components.Dashboard.ContactSuggestions do
  @moduledoc """
  Contact suggestions under an invite field: the anchor the
  `ContactSuggest` hook (`assets/js/hooks/contact_suggest.js`) fills with the
  host's contacts as they type, from the address books of their calendar
  connections (`Tymeslot.Contacts`). Placed right after the field, or after
  the form row holding it, so the list opens beneath it.

  LiveView leaves the anchor's contents to the hook (`phx-update="ignore"`).
  The words the list is announced with are rendered here, so they are in
  the host's language. They carry no count: a count would need each
  language's plural forms, and the list itself says how many there are.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  attr :for, :string, required: true, doc: "the id of the field to suggest for"

  attr :mode, :string,
    default: "replace",
    values: ["replace", "append"],
    doc: "`replace` sets the field to the address; `append` adds `Name <address>` to a list"

  attr :submit, :boolean, default: false, doc: "submit the field's form once one is chosen"
  attr :name_input, :string, default: nil, doc: "the id of a name field to fill when empty"

  attr :named, :boolean,
    default: false,
    doc: "in `replace` mode, set the field to `Name <address>` rather than the address alone"

  @spec contact_suggestions(map()) :: Phoenix.LiveView.Rendered.t()
  def contact_suggestions(assigns) do
    ~H"""
    <div
      id={"#{@for}-contact-suggest"}
      phx-hook="ContactSuggest"
      phx-update="ignore"
      data-input={@for}
      data-mode={@mode}
      data-submit={@submit}
      data-name-input={@name_input}
      data-named={@named}
      data-announce={
        dgettext("dashboard_common", "Contacts suggested. Use the arrow keys to choose one.")
      }
    >
    </div>
    """
  end
end
