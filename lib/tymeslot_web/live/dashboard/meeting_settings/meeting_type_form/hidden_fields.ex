defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.HiddenFields do
  @moduledoc """
  Hidden inputs that serialise the form's socket state into the meeting-type
  form submission.

  Only rendered while **creating** a new meeting type. Edits auto-save
  directly from socket assigns (see `MeetingTypeForm.Autosave` /
  `MeetingTypeForm.Submission`) and never post the form, so these inputs would
  be dead weight there. The shape mirrors `Submission.build_params/1` — keep
  the two in step.
  """

  use TymeslotWeb, :html

  attr :type, :any, default: nil
  attr :meeting_mode, :string, required: true
  attr :selected_icon, :string, required: true
  attr :selected_video_integration_id, :any, default: nil
  attr :selected_calendar_integration_id, :any, default: nil
  attr :selected_target_calendar_id, :any, default: nil
  attr :reminders, :list, required: true
  attr :custom_fields, :list, required: true
  attr :custom_questions_allowed, :boolean, required: true
  attr :payments_feature_enabled, :boolean, required: true
  attr :payments_charges_enabled, :boolean, required: true
  attr :payment_required, :boolean, required: true
  attr :payment_price, :string, required: true
  attr :allow_guests, :boolean, required: true

  @spec hidden_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def hidden_fields(assigns) do
    ~H"""
    <div class="contents">
      <%!-- Hidden inputs serialising custom_fields into the form submission.
           When custom questions are paywalled, we deliberately omit these so
           the form does not post `custom_fields` at all — Ecto's cast_embed
           leaves the existing embed untouched, preserving any prior questions. --%>
      <%= if @custom_questions_allowed do %>
        <%= for {field, fi} <- Enum.with_index(@custom_fields) do %>
          <input type="hidden" name={"meeting_type[custom_fields][#{fi}][id]"} value={field.id} />
          <input
            type="hidden"
            name={"meeting_type[custom_fields][#{fi}][type]"}
            value={field.type}
          />
          <input
            type="hidden"
            name={"meeting_type[custom_fields][#{fi}][label]"}
            value={field.label}
          />
          <input
            type="hidden"
            name={"meeting_type[custom_fields][#{fi}][help_text]"}
            value={field.help_text || ""}
          />
          <input
            type="hidden"
            name={"meeting_type[custom_fields][#{fi}][required]"}
            value={to_string(field.required)}
          />
          <input
            type="hidden"
            name={"meeting_type[custom_fields][#{fi}][position]"}
            value={field.position}
          />
          <%= if field.body do %>
            <input
              type="hidden"
              name={"meeting_type[custom_fields][#{fi}][body]"}
              value={field.body}
            />
          <% end %>
          <%= if field.min do %>
            <input
              type="hidden"
              name={"meeting_type[custom_fields][#{fi}][min]"}
              value={field.min}
            />
          <% end %>
          <%= if field.max do %>
            <input
              type="hidden"
              name={"meeting_type[custom_fields][#{fi}][max]"}
              value={field.max}
            />
          <% end %>
          <%= for {opt, oi} <- Enum.with_index(field.options || []) do %>
            <input
              type="hidden"
              name={"meeting_type[custom_fields][#{fi}][options][#{oi}][key]"}
              value={opt.key}
            />
            <input
              type="hidden"
              name={"meeting_type[custom_fields][#{fi}][options][#{oi}][label]"}
              value={opt.label}
            />
          <% end %>
        <% end %>
      <% end %>

      <%= for reminder <- @reminders do %>
        <input type="hidden" name="meeting_type[reminder_config][][value]" value={reminder.value} />
        <input type="hidden" name="meeting_type[reminder_config][][unit]" value={reminder.unit} />
      <% end %>
      <input
        type="hidden"
        name="meeting_type[is_active]"
        value={if @type, do: to_string(@type.is_active), else: "true"}
      />
      <input type="hidden" name="meeting_type[meeting_mode]" value={@meeting_mode} />
      <input
        type="hidden"
        name="meeting_type[video_integration_id]"
        value={@selected_video_integration_id}
      />
      <input
        type="hidden"
        name="meeting_type[calendar_integration_id]"
        value={@selected_calendar_integration_id}
      />
      <input
        type="hidden"
        name="meeting_type[target_calendar_id]"
        value={@selected_target_calendar_id}
      />
      <input type="hidden" name="meeting_type[icon]" value={@selected_icon} />
      <input
        type="hidden"
        name="meeting_type[allow_guests]"
        value={to_string(@allow_guests)}
      />
      <%!-- Payment fields are mirrored from socket state so the section's
           toggle/price controls survive re-render and post on submit. They
           are only meaningful when the host can accept charges. --%>
      <%= if @payments_feature_enabled and @payments_charges_enabled do %>
        <input
          type="hidden"
          name="meeting_type[payment_required]"
          value={to_string(@payment_required)}
        />
        <input type="hidden" name="meeting_type[price]" value={@payment_price} />
      <% end %>
    </div>
    """
  end
end
