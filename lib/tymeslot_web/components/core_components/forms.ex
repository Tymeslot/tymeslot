defmodule TymeslotWeb.Components.CoreComponents.Forms do
  @moduledoc "Form components extracted from CoreComponents."
  use Phoenix.Component

  # ========== FORM ELEMENTS ==========

  @doc """
  Renders a form field with label and error handling.
  """
  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: ""
  attr :required, :boolean, default: false
  attr :touched_fields, :list, default: []
  attr :rest, :global

  @spec form_field(map()) :: Phoenix.LiveView.Rendered.t()
  def form_field(assigns) do
    field_errors =
      if assigns.field in assigns.touched_fields do
        Keyword.get_values(assigns.form.errors, assigns.field)
      else
        []
      end

    assigns = assign(assigns, :field_errors, field_errors)

    ~H"""
    <div class="form-field">
      <label for={@field} class="form-field__label">
        {@label}
        <%= if @required do %>
          <span class="text-red-500">*</span>
        <% end %>
      </label>

      <input
        type={@type}
        id={@field}
        name={"booking[#{@field}]"}
        value={Phoenix.HTML.Form.input_value(@form, @field)}
        placeholder={@placeholder}
        class={[
          "form-field__input",
          @field_errors != [] && "form-field__input--error"
        ]}
        {@rest}
      />

      <.field_error errors={@field_errors} field={@field} />
    </div>
    """
  end

  @doc """
  Renders a textarea field with label and error handling.
  """
  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""
  attr :rows, :integer, default: 4
  attr :required, :boolean, default: false
  attr :touched_fields, :list, default: []
  attr :rest, :global

  @spec form_textarea(map()) :: Phoenix.LiveView.Rendered.t()
  def form_textarea(assigns) do
    field_errors =
      if assigns.field in assigns.touched_fields do
        Keyword.get_values(assigns.form.errors, assigns.field)
      else
        []
      end

    assigns = assign(assigns, :field_errors, field_errors)

    ~H"""
    <div class="form-field">
      <label for={@field} class="form-field__label">
        {@label}
        <%= if @required do %>
          <span class="text-red-500">*</span>
        <% end %>
      </label>

      <textarea
        id={@field}
        name={"booking[#{@field}]"}
        placeholder={@placeholder}
        rows={@rows}
        class={[
          "form-field__input",
          @field_errors != [] && "form-field__input--error"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.input_value(@form, @field) %></textarea>

      <.field_error errors={@field_errors} field={@field} />
    </div>
    """
  end

  @doc """
  Renders a field error message.
  """
  attr :errors, :list, default: []
  attr :field, :atom, required: true

  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns) do
    ~H"""
    <%= if Enum.any?(@errors) do %>
      <div class="field-error">
        {Enum.join(@errors, ", ")}
      </div>
    <% end %>
    """
  end
end
