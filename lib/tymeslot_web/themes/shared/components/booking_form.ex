defmodule TymeslotWeb.Themes.Shared.Components.BookingForm do
  @moduledoc """
  The booking step's form: name, email and message, with the anti-spam
  markup every theme's form must carry, in the one order the booking submit
  (`Shared.BookingFlow`) and the reCAPTCHA hook expect:

    * the reCAPTCHA hook attributes on the `<form>`
      (`SecurityFields.recaptcha_form_attrs/2`);
    * the honeypot field, first inside the form;
    * the hidden reCAPTCHA token input, last inside the form;
    * after the form, the inner block (a theme renders the guest field
      there), then the reCAPTCHA privacy notice.

  The reCAPTCHA pieces render only while booking reCAPTCHA is active.

  A theme varies only what is look, never structure: the form's `class`, a
  `contact_class` wrapping the name and email (Quill lays them side by side),
  the message's `message_rows`, and the field `labels` (defaults below). The
  events are the canonical `validate`, `field_blur` and `submit`
  (`Shared.StepEvents`), sent to `target`, the step component. The `<form>`
  carries the markup contract's `data-fact="attendee"`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [input: 1]

  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.Themes.Shared.SecurityFields

  @label_keys [
    :name,
    :name_placeholder,
    :email,
    :email_placeholder,
    :message,
    :message_placeholder
  ]

  attr :form, Phoenix.HTML.Form, required: true
  attr :validation_errors, :any, required: true
  attr :target, :any, required: true, doc: "the step component (`@myself`)"
  attr :class, :any, default: nil, doc: "classes on the `<form>`"

  attr :contact_class, :any,
    default: nil,
    doc: "when set, name and email sit in a `<div>` with these classes"

  attr :message_rows, :integer, default: 3

  attr :labels, :map,
    default: nil,
    doc: "labels and placeholders, keyed #{inspect(@label_keys)}; `default_labels/0` when nil"

  slot :inner_block, doc: "rendered after the form and before the reCAPTCHA notice"

  @spec booking_form(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_form(assigns) do
    assigns = assign(assigns, :labels, assigns.labels || default_labels())

    ~H"""
    <.form
      :let={f}
      for={@form}
      as={:booking}
      phx-change="validate"
      phx-submit="submit"
      phx-target={@target}
      data-testid="booking-form"
      data-fact="attendee"
      class={@class}
      id="booking-form"
      novalidate
      {SecurityFields.recaptcha_form_attrs("booking_form", "booking")}
    >
      <SecurityFields.honeypot_field id_prefix="booking" param_root="booking" />

      <div :if={@contact_class} class={@contact_class}>
        <.contact_fields
          f={f}
          labels={@labels}
          validation_errors={@validation_errors}
          target={@target}
        />
      </div>
      <.contact_fields
        :if={!@contact_class}
        f={f}
        labels={@labels}
        validation_errors={@validation_errors}
        target={@target}
      />

      <.input
        field={f[:message]}
        type="textarea"
        label={@labels.message}
        placeholder={@labels.message_placeholder}
        errors={FormValidationHelpers.field_errors(@validation_errors, :message)}
        rows={@message_rows}
        phx-debounce="blur"
        phx-blur="field_blur"
        phx-value-field="message"
        phx-target={@target}
      />

      <SecurityFields.recaptcha_token_field id_prefix="booking" param_root="booking" />
    </.form>

    {render_slot(@inner_block)}

    <SecurityFields.recaptcha_notice_block />
    """
  end

  @doc "The labels and placeholders a theme that passes none gets."
  @spec default_labels() :: %{atom() => String.t()}
  def default_labels do
    %{
      name: dgettext("booking", "Your Name"),
      name_placeholder: dgettext("booking", "John Doe"),
      email: dgettext("booking", "Email Address"),
      email_placeholder: dgettext("booking", "john@example.com"),
      message: dgettext("booking", "Additional Message (Optional)"),
      message_placeholder: dgettext("booking", "Let me know what you'd like to discuss...")
    }
  end

  attr :f, Phoenix.HTML.Form, required: true
  attr :labels, :map, required: true
  attr :validation_errors, :any, required: true
  attr :target, :any, required: true

  defp contact_fields(assigns) do
    ~H"""
    <.input
      field={@f[:name]}
      label={@labels.name}
      placeholder={@labels.name_placeholder}
      errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
      required
      phx-debounce="blur"
      phx-blur="field_blur"
      phx-value-field="name"
      phx-target={@target}
    />

    <.input
      field={@f[:email]}
      label={@labels.email}
      type="email"
      placeholder={@labels.email_placeholder}
      errors={FormValidationHelpers.field_errors(@validation_errors, :email)}
      required
      phx-debounce="blur"
      phx-blur="field_blur"
      phx-value-field="email"
      phx-target={@target}
    />
    """
  end
end
