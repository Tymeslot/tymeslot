defmodule TymeslotWeb.Dashboard.Languages.TranslationStatus do
  @moduledoc """
  How a record a dashboard form edits stands in the organiser's translation
  languages, shown on the form itself: translations are written on the
  Languages page only, and the forms say which of their texts are
  translatable, how far they have got, and where to translate them.

  `build/5` reads it from the record the form holds (each text's status per
  language is `TranslationEditor.visible_fields/3`'s, as on the Languages
  page), or returns nil when the organiser has no translation language, in
  which case every component here renders nothing:

    * `strip/1`, a line at the top of the form: the languages the booking
      page is offered in, how many of the record's texts are translated, and
      a link to the record on the Languages page (`link`);
    * `mark/1`, beside a translatable text's label: a globe, and for each
      translation language the text is missing or outdated in, a chip saying
      so.

  The link opens the review page of the translation language with the most
  missing or outdated texts of the record (the first, on a tie), with
  `?item=` naming the record's card there (`anchor/3`), which the page
  highlights, and the same as a fragment, which the browser scrolls to.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ContentTranslations.Languages
  alias TymeslotWeb.Dashboard.Languages.Labels
  alias TymeslotWeb.Dashboard.Languages.TranslationEditor

  @typedoc """
  * `fields` - for each text with an original, its status in each
    translation language, in their order;
  * `done` - how many of them are translated in every translation language.
  """
  @type t :: %{
          original: String.t(),
          locales: [String.t()],
          offer_all: boolean(),
          fields: %{String.t() => [{String.t(), atom()}]},
          done: non_neg_integer(),
          total: non_neg_integer(),
          link: String.t(),
          anchor: String.t()
        }

  @open [:missing, :outdated]

  # Stands in for the globe in the strip's sentence, so the icon can sit
  # where each language puts the placeholder.
  @globe "\u0000globe\u0000"

  @doc """
  The status of `record` (a `Catalogue` entity of `kind`, listed on the
  Languages page under `group`), or nil when `profile` has no translation
  language or the record is not saved yet. `paths:` limits it to those
  texts, for a form that edits only part of the record.
  """
  @spec build(map() | nil, atom(), atom(), struct() | nil, keyword()) :: t() | nil
  def build(profile, group, kind, record, opts \\ [])

  def build(_profile, _group, _kind, nil, _opts), do: nil
  def build(_profile, _group, _kind, %{id: nil}, _opts), do: nil

  def build(profile, group, kind, record, opts) do
    case Languages.translation_locales(profile) do
      [] -> nil
      locales -> summarise(profile, locales, anchor(group, kind, record.id), record, opts)
    end
  end

  defp summarise(profile, locales, anchor, record, opts) do
    statuses =
      for locale <- locales,
          {field, status} <- TranslationEditor.visible_fields(record, locale, opts),
          do: {field.path, locale, status}

    fields =
      Enum.group_by(statuses, &elem(&1, 0), fn {_path, locale, status} -> {locale, status} end)

    open = Enum.frequencies(for {_path, locale, status} <- statuses, status in @open, do: locale)
    target = Enum.max_by(locales, &Map.get(open, &1, 0))

    %{
      original: Languages.original(profile),
      locales: locales,
      offer_all: not Languages.restricted?(profile),
      fields: fields,
      done:
        Enum.count(fields, fn {_path, list} -> Enum.all?(list, &(elem(&1, 1) == :translated)) end),
      total: map_size(fields),
      link: review_path(target, anchor),
      anchor: anchor
    }
  end

  # The record's card on `locale`'s review page, highlighted and scrolled to.
  defp review_path(locale, anchor),
    do: ~p"/dashboard/languages/#{locale}?#{[item: anchor]}" <> "#" <> anchor

  @doc """
  The id of a record's card on the Languages review page, also the `item`
  query parameter that asks the page to highlight it.
  """
  @spec anchor(atom(), atom(), integer() | String.t()) :: String.t()
  def anchor(group, kind, id), do: "translate-#{group}-#{kind}-#{id}"

  @doc """
  The booking page's languages in a sentence: the original, then the
  translation languages, or every language with the translation languages
  named after it.
  """
  @spec offered_line(map()) :: String.t()
  def offered_line(%{offer_all: true, locales: locales}) do
    dgettext(
      "dashboard_languages",
      "Booking page in every language; your texts are translated into %{languages}.",
      languages: Enum.map_join(locales, ", ", &Labels.language_name/1)
    )
  end

  def offered_line(%{original: original, locales: locales}) do
    dgettext("dashboard_languages", "Booking page in %{languages}.",
      languages: Enum.map_join([original | locales], ", ", &language_label(&1, original))
    )
  end

  @doc """
  A language's name, marked as the original when it is `original`, as the
  Languages page lists the booking page's languages.
  """
  @spec language_label(String.t(), String.t()) :: String.t()
  def language_label(original, original),
    do:
      dgettext("dashboard_languages", "%{language} (original)",
        language: Labels.language_name(original)
      )

  def language_label(code, _original), do: Labels.language_name(code)

  attr :status, :map, default: nil, doc: "`build/5`, nil for nothing"
  attr :class, :any, default: nil, doc: "Layout classes only"

  @doc "The line at the top of a translatable form."
  @spec strip(map()) :: Phoenix.LiveView.Rendered.t()
  def strip(%{status: nil} = assigns), do: ~H""

  def strip(assigns) do
    assigns = assign(assigns, :progress, progress_parts(assigns.status))

    ~H"""
    <.card variant={:muted} padding={:xs} class={@class} data-testid="translation-strip">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2 text-token-sm text-tymeslot-700">
        <div class="flex min-w-0 grow basis-64 items-start gap-3">
          <.icon name="hero-globe-alt" class="w-5 h-5 shrink-0 text-turquoise-600" />
          <p class="min-w-0 flex-1">
            <span data-testid="translation-strip-languages">{offered_line(@status)}</span>
            <span data-testid="translation-strip-progress">
              {@progress.before}<.icon
                name="hero-globe-alt-mini"
                class="inline w-4 h-4 align-text-bottom text-turquoise-600"
              /><span class="sr-only">{dgettext("dashboard_languages", "globe")}</span>{@progress.after}
            </span>
          </p>
        </div>
        <.action_link
          patch={@status.link}
          variant={:ghost}
          size={:sm}
          icon="hero-language"
          data-testid="translation-strip-link"
        >
          {dgettext("dashboard_languages", "Translate on the Languages page")}
        </.action_link>
      </div>
    </.card>
    """
  end

  defp progress_parts(%{total: 0}),
    do:
      split(
        dgettext("dashboard_languages", "Texts marked %{globe} are translatable.", globe: @globe)
      )

  defp progress_parts(%{done: done, total: total}) do
    split(
      dngettext(
        "dashboard_languages",
        "Texts marked %{globe} are translatable: %{done} of %{count} done.",
        "Texts marked %{globe} are translatable: %{done} of %{count} done.",
        total,
        globe: @globe,
        done: done
      )
    )
  end

  # A translation that dropped the placeholder still reads; the globe then
  # goes at its end.
  defp split(text) do
    case String.split(text, @globe, parts: 2) do
      [before, rest] -> %{before: before, after: rest}
      [whole] -> %{before: whole <> " ", after: ""}
    end
  end

  attr :status, :map, default: nil, doc: "`build/5`, nil for nothing"
  attr :path, :string, default: nil, doc: "The text the label is for"

  attr :prefix, :string,
    default: nil,
    doc: "Every text whose path starts with it, for a section (a meeting type's questions)"

  @doc """
  The globe beside a translatable text's label, with a chip for each
  translation language the text is missing or outdated in (for a section,
  `prefix`, missing wins over outdated).
  """
  @spec mark(map()) :: Phoenix.LiveView.Rendered.t()
  def mark(%{status: nil} = assigns), do: ~H""

  def mark(assigns) do
    assigns = assign(assigns, :open, open_statuses(assigns))

    ~H"""
    <span
      class="inline-flex flex-wrap items-center gap-1.5 align-middle"
      data-testid="translation-mark"
      data-path={@path || @prefix}
    >
      <.icon name="hero-globe-alt-mini" class="w-4 h-4 shrink-0 text-turquoise-600" />
      <span class="sr-only">{dgettext("dashboard_languages", "Translatable")}</span>
      <.link
        :for={{locale, status} <- @open}
        patch={review_path(locale, @status.anchor)}
        class="rounded-token-full transition-opacity hover:opacity-80 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-turquoise-500"
        aria-label={chip_link_label(locale, status)}
        data-testid="translation-chip"
        data-locale={locale}
        data-status={status}
      >
        <.pill tone={:warning} dot>
          {chip_text(locale, status)}
          <.icon name="hero-arrow-right-micro" class="ml-0.5 w-3 h-3" />
        </.pill>
      </.link>
    </span>
    """
  end

  defp open_statuses(%{status: status, path: path}) when is_binary(path),
    do:
      for(
        {locale, state} <- Map.get(status.fields, path, []),
        state in @open,
        do: {locale, state}
      )

  defp open_statuses(%{status: status, prefix: prefix}) when is_binary(prefix) do
    for locale <- status.locales,
        state = worst(status.fields, prefix, locale),
        do: {locale, state}
  end

  defp worst(fields, prefix, locale) do
    states =
      for {path, list} <- fields,
          String.starts_with?(path, prefix),
          {^locale, state} <- list,
          do: state

    cond do
      :missing in states -> :missing
      :outdated in states -> :outdated
      true -> nil
    end
  end

  defp chip_link_label(locale, status),
    do:
      dgettext("dashboard_languages", "%{status}. Translate it on the Languages page.",
        status: chip_text(locale, status)
      )

  defp chip_text(locale, :missing),
    do:
      dgettext("dashboard_languages", "%{language}: missing",
        language: Labels.language_name(locale)
      )

  defp chip_text(locale, :outdated),
    do:
      dgettext("dashboard_languages", "%{language}: outdated",
        language: Labels.language_name(locale)
      )
end
