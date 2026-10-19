defmodule Tymeslot.Utils.ChangesetErrors do
  @moduledoc """
  Changeset errors as text, the same way for the web layer's form errors and
  the domain's own formatters.

  `translate/1` is the domain's copy of `Forms.translate_error/1` (the domain
  may not call the web layer): both look a message up in the `errors` domain,
  where every changeset message is registered. `first/2` takes the translate
  function as an argument, so either side can pick a single-line error.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  @type translate :: ({String.t(), keyword()} -> String.t())

  @doc """
  One `{message, opts}` error in the current locale. The message is a
  runtime value, so its msgid is registered where it is written
  (`dgettext_noop/2`) or in `TymeslotWeb.Gettext.EctoErrorMsgids`.
  """
  @spec translate({String.t(), keyword()}) :: String.t()
  def translate({message, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(TymeslotWeb.Gettext, "errors", message, message, count, opts)
    else
      Gettext.dgettext(TymeslotWeb.Gettext, "errors", message, opts)
    end
  end

  @doc """
  Each field's first error in the current locale: `%{field => message}`.
  """
  @spec first_per_field(Changeset.t()) :: %{atom() => String.t()}
  def first_per_field(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(&translate/1)
    |> Map.new(fn {field, errors} -> {field, first_message(errors)} end)
  end

  @doc """
  The first error of the first field alphabetically, for one line of text;
  `nil` when the changeset has no errors.

  Shown next to its field, the message stands alone. Shown anywhere else (a
  flash), the caller passes `labels`, translated names for the fields it can
  refuse, and a labelled field reads "Label: message". A field without a
  label gives the message alone: a field name is never made up from the
  atom, and translated text is never re-cased.
  """
  @spec first(Changeset.t(), translate(), %{atom() => String.t()}) :: String.t() | nil
  def first(%Changeset{} = changeset, translate, labels \\ %{}) do
    case changeset |> Changeset.traverse_errors(translate) |> Enum.sort_by(&elem(&1, 0)) do
      [{field, errors} | _others] -> labelled(Map.get(labels, field), first_message(errors))
      [] -> nil
    end
  end

  defp labelled(nil, message), do: message

  defp labelled(label, message),
    do: dgettext("errors", "%{field}: %{message}", field: label, message: message)

  @doc """
  The first message in one field's traversed errors. An embedded or
  associated field nests its errors (a map for one, a list of maps for many);
  its first message is the first one found depth-first.
  """
  @spec first_message(term()) :: String.t() | nil
  def first_message([message | _rest]) when is_binary(message), do: message
  def first_message(nested) when is_list(nested), do: Enum.find_value(nested, &first_message/1)

  def first_message(nested) when is_map(nested),
    do: nested |> Enum.sort_by(&elem(&1, 0)) |> Enum.find_value(&first_message(elem(&1, 1)))

  def first_message(_none), do: nil
end
