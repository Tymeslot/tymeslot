defmodule TymeslotWeb.Integrations.Providers.GenericProviderFormComponent do
  @moduledoc """
  Generic provider setup form component.

  Renders a form from a provider's config_schema. Providers with custom UX can
  expose their own setup component; otherwise this generic component is used.
  """
  use TymeslotWeb, :live_component

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <.form for={@form} id={@id} phx-target={@myself} phx-submit="save">
        <%= for {field, spec} <- @schema do %>
          <div class="mb-4">
            {render_field(@form, field, spec)}
          </div>
        <% end %>
        <div class="mt-6">
          <.action_button type="submit">Save</.action_button>
        </div>
      </.form>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    form = assigns[:form] || to_form(%{})
    {:ok, assign(socket, Map.merge(%{form: form}, Map.take(assigns, [:id, :schema, :action])))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"_target" => _target} = params, socket) do
    send(self(), {:provider_form_submit, params})
    {:noreply, socket}
  end

  # --- helpers ---

  defp render_field(form, field, %{type: :string} = spec) do
    assigns = %{
      form: form,
      field: field,
      spec: spec
    }

    ~H"""
    <label class="block text-sm font-medium text-tymeslot-700 mb-1">{label_for(@field, @spec)}</label>
    <input
      type="text"
      name={@form[Atom.to_string(@field)].name}
      value={@form[Atom.to_string(@field)].value}
      class="w-full px-3 py-2 input focus:outline-hidden focus:ring-2 focus:ring-teal-500 focus:border-transparent"
    />
    """
  end

  defp render_field(form, field, %{type: :datetime} = spec) do
    assigns = %{form: form, field: field, spec: spec}

    ~H"""
    <label class="block text-sm font-medium text-tymeslot-700 mb-1">{label_for(@field, @spec)}</label>
    <input
      type="datetime-local"
      name={@form[Atom.to_string(@field)].name}
      value={@form[Atom.to_string(@field)].value}
      class="w-full px-3 py-2 input focus:outline-hidden focus:ring-2 focus:ring-teal-500 focus:border-transparent"
    />
    """
  end

  defp render_field(form, field, %{type: :boolean} = spec) do
    assigns = %{form: form, field: field, spec: spec}

    ~H"""
    <div class="flex items-center">
      <input
        type="checkbox"
        id={@form[Atom.to_string(@field)].id}
        name={@form[Atom.to_string(@field)].name}
        checked={@form[Atom.to_string(@field)].value}
        value="true"
        class="h-4 w-4 text-teal-600 rounded focus:ring-teal-500 border-tymeslot-300"
      />
      <label for={@form[Atom.to_string(@field)].id} class="ml-2 block text-sm text-tymeslot-700">
        {label_for(@field, @spec)}
      </label>
    </div>
    """
  end

  defp render_field(form, field, spec) do
    # Fallback to text for unknown types
    render_field(form, field, Map.put(spec, :type, :string))
  end

  defp label_for(field, spec) do
    spec[:label] || field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
