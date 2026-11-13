defmodule TymeslotWeb.Components.CoreComponents.DateTimePicker do
  @moduledoc """
  Date, time and date-time fields: a typed field and a button that opens an
  in-house panel, or, on a touch device, the system's own picker.

  Every value is posted by a hidden input named like the field, in the ISO form
  the native control would send (`2026-11-14`, `14:30`, `2026-11-14T14:30`), so
  a form and its changeset see no difference. A choice fires `input` on that
  input, so `phx-change` works unchanged, on the form or on the field (`@rest`
  carries `phx-*` attributes onto the hidden input).

  What the visitor reads is rendered here, in their language and clock, so a
  page shows it before the `DateTimePicker` hook (`assets/js/hooks/date_time_picker.js`)
  connects. The hook then parses what is typed and draws the panels: a month
  grid (the same six by seven weeks as the calendar's mini month, on the
  viewer's week start) and a list of quarter hours (`TimeOptions`), placed by
  `assets/js/floating_panel.js`.

  On a device whose primary pointer is coarse the native control is the visible
  one, because the system wheel or sheet is the better experience on a phone,
  and a browser without the Popover API gets it too. That is a CSS decision
  (`.date-time-picker-native`), so a page never flashes the wrong control.

  The week start and clock come from `PickerPreferences` unless given directly.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents.DateTimePicker.Attrs
  import TymeslotWeb.Components.CoreComponents.Dropdown, only: [dropdown_panel: 1]
  import TymeslotWeb.Components.CoreComponents.Forms, only: [label: 1, field_error: 1]
  import TymeslotWeb.Components.CoreComponents.Icons, only: [icon: 1]

  alias Phoenix.HTML.FormField
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.CoreComponents.DateTimePicker.Value
  alias TymeslotWeb.Components.Shared.PickerPreferences
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Helpers.LocaleFormat

  # One sample per locale is enough: every date is drawn from this shape.
  @pattern_date ~D[2000-01-02]
  @sample_date ~D[2026-02-05]
  @sample_time ~T[09:00:00]
  @native_types %{date: "date", time: "time", datetime: "datetime-local"}

  @doc """
  Renders a date field posting `YYYY-MM-DD`.

  ## Examples

      <.date_picker field={@form[:expires_on]} label="Expires on" min={@today} />
      <.date_picker id="until" name="until" value={@until} aria-label="Repeat until" />
  """
  picker_attrs()
  @spec date_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def date_picker(assigns), do: assigns |> assign(:kind, :date) |> picker()

  @doc "Renders a time field posting `HH:MM`, in the viewer's clock."
  picker_attrs()
  @spec time_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def time_picker(assigns), do: assigns |> assign(:kind, :time) |> picker()

  @doc """
  Renders a date and a time as one field, posting `YYYY-MM-DDTHH:MM` once both
  are known. Until then it posts the half it has (`YYYY-MM-DD` or `THH:MM`) and
  shows what is missing under itself, so a form refuses the value rather than
  read it as blank: `DateTimePicker.Value.parse/1` reads it.
  """
  picker_attrs()
  @spec datetime_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def datetime_picker(assigns), do: assigns |> assign(:kind, :datetime) |> picker()

  defp picker(%{field: %FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns[:id] || field.id, name: assigns[:name] || field.name)
    |> assign(value: assigns[:value] || field.value)
    |> assign(errors: (assigns[:errors] || []) ++ field.errors)
    |> picker()
  end

  defp picker(assigns) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    time_format = PickerPreferences.time_format(assigns.time_format, locale)
    week_start = PickerPreferences.week_start(assigns.week_start)
    value = iso_value(assigns[:value])
    errors = field_errors(assigns.kind, value, assigns.errors)
    error_id = errors != [] && "#{assigns.id}-error"

    assigns =
      assign(
        assigns,
        Map.merge(split_rest(assigns.rest, error_id), %{
          value: value,
          errors: errors,
          error_id: error_id,
          native_type: Map.fetch!(@native_types, assigns.kind),
          field_name: assigns.label || assigns.rest[:"aria-label"] || default_name(assigns.kind),
          date_id: assigns.id,
          time_id: if(assigns.kind == :datetime, do: "#{assigns.id}-time", else: assigns.id),
          date_text: date_text(value, assigns.kind, locale),
          time_text: time_text(value, assigns.kind, time_format),
          date_placeholder: assigns.placeholder || date_sample(locale),
          time_placeholder: assigns.placeholder || TimeFormat.format(@sample_time, time_format),
          config: Jason.encode!(config(assigns, locale, time_format, week_start)),
          weekdays: weekdays(week_start, locale),
          min: iso_bound(assigns.min),
          max: iso_bound(assigns.max)
        })
      )

    ~H"""
    <div
      id={"#{@id}-field"}
      class={[
        "form-field-wrapper date-time-picker",
        @variant != :default && "date-time-picker--#{@variant}",
        @class
      ]}
      phx-hook="DateTimePicker"
      data-picker-kind={@kind}
      data-picker-config={@config}
      {@root_rest}
    >
      <.label :if={@label} id={"#{@id}-label"} for={@id}>
        {@label}
        <span :if={@required} class="text-red-500 ml-0.5">*</span>
      </.label>
      <span :if={!@label} id={"#{@id}-label"} hidden>{@field_name}</span>
      <span :if={@kind == :datetime} id={"#{@id}-time-name"} hidden>
        {dgettext("common", "Time")}
      </span>

      <p
        :if={@description != []}
        class="text-token-xs text-tymeslot-500 font-medium normal-case tracking-normal -mt-1 mb-2"
      >
        {render_slot(@description)}
      </p>

      <div class="date-time-picker-fields">
        <input
          type="hidden"
          data-picker-value
          name={@name}
          value={@value}
          disabled={@disabled}
          {@value_rest}
        />

        <.date_part
          :if={@kind in [:date, :datetime]}
          id={@date_id}
          field_id={@id}
          text={@date_text}
          placeholder={@date_placeholder}
          errors={@errors}
          required={@required}
          disabled={@disabled}
          describedby={@describedby}
          text_rest={@text_rest}
          weekdays={@weekdays}
        />

        <.time_part
          :if={@kind in [:time, :datetime]}
          id={@time_id}
          field_id={@id}
          kind={@kind}
          text={@time_text}
          placeholder={@time_placeholder}
          errors={@errors}
          required={@required}
          disabled={@disabled}
          describedby={@describedby}
          text_rest={if(@kind == :time, do: @text_rest, else: [])}
        />

        <%!-- raw-input: the visible control on a touch device and in a browser without popovers; it has no name because the hidden input posts the value --%>
        <input
          id={"#{@id}-native"}
          data-picker-native
          type={@native_type}
          value={@value}
          min={@min}
          max={@max}
          class={["input date-time-picker-native", @errors != [] && "input-error"]}
          disabled={@disabled}
          aria-labelledby={"#{@id}-label"}
          aria-invalid={@errors != [] && "true"}
          aria-required={@required && "true"}
          aria-describedby={@describedby}
        />
      </div>

      <.field_error errors={@errors} id={@error_id} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field_id, :string, required: true
  attr :text, :string, required: true
  attr :placeholder, :string, required: true
  attr :errors, :list, required: true
  attr :required, :boolean, required: true
  attr :disabled, :boolean, required: true
  attr :describedby, :string, required: true
  attr :text_rest, :list, required: true
  attr :weekdays, :list, required: true

  defp date_part(assigns) do
    ~H"""
    <div class="date-time-picker-control" data-picker-part="date">
      <%!-- raw-input: the typed half of a picker; the hidden input posts the value, so it has no name --%>
      <input
        type="text"
        id={@id}
        data-picker-text
        autocomplete="off"
        value={@text}
        placeholder={@placeholder}
        class={["input date-time-picker-text", @errors != [] && "input-error"]}
        disabled={@disabled}
        aria-labelledby={"#{@field_id}-label"}
        aria-invalid={@errors != [] && "true"}
        aria-required={@required && "true"}
        aria-describedby={@describedby}
        {@text_rest}
      />
      <button
        type="button"
        id={"#{@id}-trigger"}
        data-picker-trigger
        class="date-time-picker-trigger"
        disabled={@disabled}
        aria-label={dgettext("common", "Choose date")}
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls={"#{@field_id}-date-panel"}
      >
        <.icon name="hero-calendar" class="date-time-picker-icon" />
      </button>

      <%!-- Named by kind: the panel keeps its content across patches, so a field
           that changes kind (a question switched from Date to Time) must get a
           new panel rather than the old one's grid. --%>
      <.dropdown_panel
        id={"#{@field_id}-date-panel"}
        role="dialog"
        class="select-panel date-time-picker-panel date-picker-panel"
        unstyled
        panel_label={dgettext("common", "Choose date")}
        panel_attrs={[
          {"popover", "manual"},
          {"phx-update", "ignore"},
          {"tabindex", "-1"},
          {"aria-modal", "true"},
          {"data-picker-panel", true}
        ]}
      >
        <div class="date-picker-header">
          <button
            type="button"
            class="date-picker-nav"
            data-picker-prev
            aria-label={dgettext("common", "Previous month")}
          >
            <.icon name="hero-chevron-left" class="date-time-picker-icon" />
          </button>
          <div id={"#{@id}-month"} class="date-picker-month" aria-live="polite" data-picker-month>
          </div>
          <button
            type="button"
            class="date-picker-nav"
            data-picker-next
            aria-label={dgettext("common", "Next month")}
          >
            <.icon name="hero-chevron-right" class="date-time-picker-icon" />
          </button>
        </div>
        <table class="date-picker-grid" role="grid" aria-labelledby={"#{@id}-month"}>
          <thead>
            <tr>
              <th :for={{short, full} <- @weekdays} scope="col" abbr={full}>{short}</th>
            </tr>
          </thead>
          <tbody data-picker-days></tbody>
        </table>
      </.dropdown_panel>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field_id, :string, required: true
  attr :kind, :atom, required: true
  attr :text, :string, required: true
  attr :placeholder, :string, required: true
  attr :errors, :list, required: true
  attr :required, :boolean, required: true
  attr :disabled, :boolean, required: true
  attr :describedby, :string, required: true
  attr :text_rest, :list, required: true

  defp time_part(assigns) do
    assigns =
      assign(
        assigns,
        :labelled_by,
        if(assigns.kind == :datetime,
          do: "#{assigns.field_id}-label #{assigns.field_id}-time-name",
          else: "#{assigns.field_id}-label"
        )
      )

    ~H"""
    <div class="date-time-picker-control" data-picker-part="time">
      <%!-- raw-input: the typed half of a picker; the hidden input posts the value, so it has no name --%>
      <input
        type="text"
        id={@id}
        data-picker-text
        autocomplete="off"
        value={@text}
        placeholder={@placeholder}
        class={["input date-time-picker-text", @errors != [] && "input-error"]}
        disabled={@disabled}
        aria-labelledby={@labelled_by}
        aria-invalid={@errors != [] && "true"}
        aria-required={@required && "true"}
        aria-describedby={@describedby}
        {@text_rest}
      />
      <button
        type="button"
        id={"#{@id}-trigger"}
        data-picker-trigger
        class="date-time-picker-trigger"
        disabled={@disabled}
        aria-label={dgettext("common", "Choose time")}
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@field_id}-time-panel"}
      >
        <.icon name="hero-clock" class="date-time-picker-icon" />
      </button>

      <.dropdown_panel
        id={"#{@field_id}-time-panel"}
        role="listbox"
        class="select-panel date-time-picker-panel"
        unstyled
        panel_label={dgettext("common", "Choose time")}
        panel_attrs={[
          {"popover", "manual"},
          {"phx-update", "ignore"},
          {"tabindex", "-1"},
          {"data-picker-panel", true}
        ]}
      />
    </div>
    """
  end

  defp default_name(:date), do: dgettext("common", "Date")
  defp default_name(:time), do: dgettext("common", "Time")
  defp default_name(:datetime), do: dgettext("common", "Date and time")

  # A half-filled date and time is the field's own error. Whatever the form
  # said of it was said of a value it could not read, so this replaces it.
  defp field_errors(:datetime, value, errors) do
    case Value.unfinished(value) do
      nil -> errors
      reason -> [Value.message(reason)]
    end
  end

  defp field_errors(_kind, _value, errors), do: errors

  # What the hook needs and the page has already said once in its language.
  defp config(%{kind: kind, today: today}, locale, time_format, week_start) do
    %{locale: locale, weekStart: if(week_start == :sunday, do: 0, else: 1)}
    |> maybe_merge(iso_bound(today) != nil, fn -> %{today: iso_bound(today)} end)
    |> maybe_merge(kind != :time, fn -> date_config(locale) end)
    |> maybe_merge(kind != :date, fn -> time_config(time_format) end)
  end

  defp maybe_merge(map, true, extra), do: Map.merge(map, extra.())
  defp maybe_merge(map, false, _extra), do: map

  defp date_config(locale) do
    %{
      datePattern: date_pattern(locale),
      shortMonths: LocaleFormat.get_month_names(locale, :short),
      longMonths: LocaleFormat.get_month_names(locale, :full),
      monthHeadings:
        Enum.map(1..12, fn month ->
          month |> LocaleFormat.format_month_year(2000, locale) |> String.replace("2000", "{y}")
        end)
    }
  end

  defp time_config(time_format) do
    %{
      timeFormat: time_format,
      timeOptions: time_format |> TimeOptions.time_options() |> Enum.map(&Tuple.to_list/1)
    }
  end

  # The one format is `LocaleFormat`'s; the hook fills this in for a date it
  # has just been given, so it can never disagree with what the server renders.
  defp date_pattern(locale) do
    short_month = LocaleFormat.format_month_name(@pattern_date.month, locale, :short)

    @pattern_date
    |> LocaleFormat.format_short_date_with_year(locale)
    |> String.replace(Integer.to_string(@pattern_date.year), "{y}")
    |> String.replace(short_month, "{m}")
    |> String.replace(Integer.to_string(@pattern_date.day), "{d}")
  end

  defp date_sample(locale), do: LocaleFormat.format_short_date_with_year(@sample_date, locale)

  # Sunday-first names rotated to the viewer's week, as the mini month shows.
  defp weekdays(week_start, locale) do
    short = LocaleFormat.get_weekday_names(locale, :short)
    full = LocaleFormat.get_weekday_names(locale, :full)
    days = Enum.zip(short, full)

    case week_start do
      :sunday -> days
      :monday -> Enum.drop(days, 1) ++ Enum.take(days, 1)
    end
  end

  defp date_text(value, kind, locale) when kind in [:date, :datetime] do
    with date when is_binary(date) <- date_portion(value, kind),
         {:ok, parsed} <- Date.from_iso8601(date) do
      LocaleFormat.format_short_date_with_year(parsed, locale)
    else
      _no_date -> ""
    end
  end

  defp date_text(_value, _kind, _locale), do: ""

  defp time_text(value, kind, time_format) when kind in [:time, :datetime] do
    with time when is_binary(time) <- time_portion(value, kind),
         {:ok, parsed} <- Time.from_iso8601(time <> ":00") do
      TimeFormat.format(parsed, time_format)
    else
      _no_time -> ""
    end
  end

  defp time_text(_value, _kind, _time_format), do: ""

  defp date_portion(value, :date), do: value
  defp date_portion(value, :datetime), do: value |> String.split("T", parts: 2) |> List.first()

  defp time_portion(value, :time), do: String.slice(value, 0, 5)

  defp time_portion(value, :datetime) do
    case String.split(value, "T", parts: 2) do
      [_date, time] -> String.slice(time, 0, 5)
      _no_time -> nil
    end
  end

  defp iso_value(nil), do: ""
  defp iso_value(value) when is_binary(value), do: value
  defp iso_value(%Date{} = date), do: Date.to_iso8601(date)
  defp iso_value(%Time{} = time), do: time |> Time.to_iso8601() |> String.slice(0, 5)
  defp iso_value(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%dT%H:%M")
  defp iso_value(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%dT%H:%M")
  defp iso_value(other), do: to_string(other)

  defp iso_bound(nil), do: nil
  defp iso_bound(value), do: value |> iso_value() |> String.slice(0, 10) |> blank_to_nil()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Sorts `@rest` as `Select` does; the typed field also takes `autofocus`, so
  # a booking question can open on it. Only the typed field: the native control
  # is hidden off touch, and the hook moves the focus to it where it is the one
  # on show.
  defp split_rest(rest, error_id) do
    {value_rest, others} = Enum.split_with(rest, fn {key, _value} -> value_attr?(key) end)
    {aria_rest, others} = Enum.split_with(others, fn {key, _value} -> aria_attr?(key) end)
    {text_rest, root_rest} = Enum.split_with(others, fn {key, _value} -> key == :autofocus end)

    %{
      value_rest: value_rest,
      text_rest: text_rest,
      root_rest: root_rest,
      describedby: describedby(aria_rest[:"aria-describedby"], error_id)
    }
  end

  defp value_attr?(key), do: key == :form or match?("phx-" <> _rest, to_string(key))
  defp aria_attr?(key), do: match?("aria-" <> _rest, to_string(key))

  defp describedby(nil, false), do: nil
  defp describedby(explicit, false), do: explicit
  defp describedby(nil, error_id), do: error_id
  defp describedby(explicit, error_id), do: "#{explicit} #{error_id}"
end
