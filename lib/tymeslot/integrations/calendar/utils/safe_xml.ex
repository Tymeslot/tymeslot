defmodule Tymeslot.Integrations.Calendar.Utils.SafeXml do
  @moduledoc """
  The one entry point for parsing XML that arrives from a remote server.

  CalDAV and EWS responses come from a server the user nominated, so they are
  untrusted input. xmerl's DOM scanner (what `SweetXml.parse/2` runs) turns
  every element name, attribute name and namespace prefix it meets into an
  atom. Atoms are never garbage collected, so a hostile server answering with
  documents full of unique names fills the atom table over a few syncs, and
  the VM aborts for every tenant on the node.

  This module parses with `:xmerl_sax_parser` instead, which reports names as
  strings, and builds a small tree of `%SafeXml{}` elements whose names stay
  binaries. Nothing in a document becomes an atom.

  A `DOCTYPE` naming an external DTD or carrying an internal subset is refused
  before the parser reads any declaration in it: no response either protocol
  defines has one, and refusing it rules out entity expansion and any fetch of
  an external DTD in one place. A bare `<!DOCTYPE name>`, with neither, is
  accepted and ignored: it declares nothing, and the parser reports no start
  of a DTD for it to refuse. Byte caps stay with the callers, which know
  their protocol's budget.

  Elements nested more than 64 deep are refused at the first one past the
  limit. The deepest CalDAV or EWS response nests about a dozen levels, and
  callers that match an element and then search beneath each match take time
  quadratic in the nesting, so a hostile server could otherwise spend minutes
  of a sync on one document that fits its byte cap.

  ## Queries

  `xpath/2,3` evaluates the expressions SweetXml's `~x` sigil builds, so the
  modifiers (`s`, `l`, `o`), `transform_by/2`, subspecs and prefixes bound
  with `SweetXml.add_namespace/3` all read as they do there. Only a subset of
  XPath is understood, the one these protocols need:

    * a path starting at the context node (`./`, `.//`) or at a document
      wrapping it (`/`, `//`), its steps joined by `/` or `//`;
    * an element step named `local`, `prefix:local` (matched on the namespace
      the prefix is bound to, never on the prefix the server chose), or
      `*[local-name()='a' or local-name()='b']`;
    * a final `text()` or `@attribute` step.

  Anything else raises `ArgumentError`: an expression outside the subset is a
  programming error, and failing loudly beats answering an empty result.
  Text and attribute values come back as binaries, never charlists.
  """

  @enforce_keys [:namespace, :name]
  defstruct [:namespace, :name, attributes: [], children: []]

  @typedoc """
  A parsed element. `namespace` is its namespace URI (`""` for none), `name`
  its local name, and `attributes` holds `{namespace, local_name, value}`.
  Adjacent text, CDATA included, is merged into one binary child.
  """
  @type t :: %__MODULE__{
          namespace: String.t(),
          name: String.t(),
          attributes: [{String.t(), String.t(), String.t()}],
          children: [t() | String.t()]
        }

  @typedoc "An xpath expression, as built by SweetXml's `~x` sigil."
  @type spec :: %SweetXpath{}

  @typedoc """
  Why a document could not be parsed. No form quotes the document: the
  parser's own reason names elements out of it, and callers log this term.
  """
  @type parse_error ::
          :doctype_not_allowed | :too_deep | {:malformed_xml, line :: pos_integer() | nil}

  # Deepest element nesting accepted; see the moduledoc.
  @max_depth 64

  # Belt and braces behind the `startDTD` refusal in `handle_event/3`.
  @sax_options [:skip_external_dtd, :disallow_entities, {:external_entities, :none}]

  @doc """
  Parses `xml` into its root element.

  Returns `{:error, :doctype_not_allowed}` for a document whose `DOCTYPE`
  names an external DTD or carries an internal subset,
  `{:error, :too_deep}` for one nesting elements past the depth limit, and
  `{:error, {:malformed_xml, line}}` for one that is not well-formed. Never
  raises or exits on bad input.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, parse_error()}
  def parse(xml) when is_binary(xml) do
    xml
    |> :xmerl_sax_parser.stream(
      [event_fun: &handle_event/3, event_state: {[], 0, nil}] ++ @sax_options
    )
    |> parse_result()
  catch
    # Defensive: the parser converts its own failures into return values.
    _kind, _reason -> {:error, {:malformed_xml, nil}}
  end

  defp parse_result({:ok, {[], 0, %__MODULE__{} = root}, _rest}), do: {:ok, root}
  defp parse_result({:ok, _state, _rest}), do: {:error, {:malformed_xml, nil}}

  defp parse_result({:doctype_not_allowed, _location, _reason, _tags, _state}),
    do: {:error, :doctype_not_allowed}

  defp parse_result({:too_deep, _location, _reason, _tags, _state}), do: {:error, :too_deep}

  defp parse_result({_tag, {_current, _entity, line}, _reason, _tags, _state})
       when is_integer(line),
       do: {:error, {:malformed_xml, line}}

  defp parse_result(_other), do: {:error, {:malformed_xml, nil}}

  # The event state is `{open_elements, depth, root}`. Each open element is
  # held as `{element, children_reversed}`, its children filled in when it
  # closes; `depth` counts them, so the limit costs nothing per event.
  #
  # A DOCTYPE ends the parse before any declaration in it is read, and an
  # element past the depth limit before anything beneath it is. The parser
  # turns a thrown `{tag, reason}` into its `{tag, location, reason, end_tags,
  # state}` return, which `parse_result/1` matches.
  defp handle_event({:startDTD, _name, _public_id, _system_id}, _location, _state),
    do: throw({:doctype_not_allowed, :refused})

  defp handle_event({:startElement, _uri, _local, _qualified, _attrs}, _location, state)
       when elem(state, 1) >= @max_depth,
       do: throw({:too_deep, :refused})

  defp handle_event(
         {:startElement, uri, local_name, _qualified, attributes},
         _location,
         {open, depth, root}
       ) do
    element = %__MODULE__{
      namespace: to_binary(uri),
      name: to_binary(local_name),
      attributes:
        Enum.map(attributes, fn {attr_uri, _prefix, attr_name, value} ->
          {to_binary(attr_uri), to_binary(attr_name), to_binary(value)}
        end)
    }

    {[{element, []} | open], depth + 1, root}
  end

  defp handle_event(
         {:endElement, _uri, _local_name, _qualified},
         _location,
         {open, depth, root}
       ) do
    [{element, children} | rest] = open
    closed = %{element | children: finalise_children(children)}

    case rest do
      [] -> {[], 0, closed}
      [{parent, siblings} | outer] -> {[{parent, [closed | siblings]} | outer], depth - 1, root}
    end
  end

  defp handle_event({kind, chars}, _location, {[{element, children} | rest], depth, root})
       when kind in [:characters, :ignorableWhitespace] do
    {[{element, [{:text, chars} | children]} | rest], depth, root}
  end

  defp handle_event(_event, _location, state), do: state

  # Merges runs of adjacent text (the parser reports CDATA sections and the
  # text around them separately) into one binary, restoring document order.
  defp finalise_children(reversed) do
    reversed
    |> Enum.reduce([], fn
      {:text, chars}, [{:text, later} | acc] -> [{:text, [chars | later]} | acc]
      child, acc -> [child | acc]
    end)
    |> Enum.map(fn
      {:text, chardata} -> to_binary(chardata)
      element -> element
    end)
  end

  defp to_binary(chardata), do: :unicode.characters_to_binary(chardata)

  @doc """
  Evaluates a `~x` expression against `node`, as `SweetXml.xpath/3` would.

  With subspecs, each match is mapped to `%{key => xpath(match, subspec)}`; a
  subspec may itself be `[spec | subspecs]` to nest.
  """
  @spec xpath(t(), spec(), keyword()) :: term()
  def xpath(node, spec, subspecs \\ [])

  def xpath(node, %SweetXpath{is_list: true} = spec, []) do
    node |> select(spec) |> Enum.map(&cast(&1, spec.cast_to)) |> spec.transform_fun.()
  end

  def xpath(node, %SweetXpath{cast_to: cast_to} = spec, [])
      when cast_to in [:string, :soft_string] do
    # As in SweetXml, a string cast reads every match and concatenates them.
    node |> select(spec) |> Enum.map_join(&cast(&1, cast_to)) |> spec.transform_fun.()
  end

  def xpath(node, %SweetXpath{} = spec, []) do
    node |> select(spec) |> List.first() |> cast(spec.cast_to) |> spec.transform_fun.()
  end

  def xpath(node, %SweetXpath{is_list: true} = spec, subspecs) do
    node |> xpath(spec) |> Enum.map(&xmap(&1, subspecs))
  end

  def xpath(node, %SweetXpath{} = spec, subspecs) do
    case xpath(node, spec) do
      nil -> nil
      match -> xmap(match, subspecs)
    end
  end

  defp xmap(node, subspecs) do
    Map.new(subspecs, fn
      {key, [%SweetXpath{} = spec | nested]} -> {key, xpath(node, spec, nested)}
      {key, %SweetXpath{} = spec} -> {key, xpath(node, spec)}
    end)
  end

  defp cast(value, false), do: value
  defp cast(nil, _cast_to), do: nil
  defp cast(value, _cast_to) when is_binary(value), do: value

  defp cast(%__MODULE__{} = element, cast_to) when cast_to in [:string, :soft_string],
    do: text_content(element)

  defp cast(_value, cast_to),
    do: raise(ArgumentError, "SafeXml does not support the #{inspect(cast_to)} cast")

  defp text_content(%__MODULE__{children: children}) do
    Enum.map_join(children, fn
      text when is_binary(text) -> text
      element -> text_content(element)
    end)
  end

  # -- Path evaluation --------------------------------------------------------

  defp select(node, %SweetXpath{path: path, namespaces: namespaces}) do
    {origin, steps} = compile(to_string(path), namespaces)
    start = if origin == :document, do: {:document, node}, else: node

    Enum.reduce(steps, [start], fn step, nodes -> Enum.flat_map(nodes, &apply_step(&1, step)) end)
  end

  defp apply_step(node, {axis, {:attribute, name}}) do
    owners = if axis == :child, do: [node], else: [node | descendants(node)]

    for %__MODULE__{attributes: attributes} <- owners,
        {"", ^name, value} <- attributes,
        do: value
  end

  defp apply_step(node, {axis, test}) do
    candidates = if axis == :child, do: children(node), else: descendants(node)
    Enum.filter(candidates, &matches?(&1, test))
  end

  # A path starting with `/` or `//` is evaluated against a document whose
  # only child is the node passed in, which is how xmerl reads an absolute
  # path given an element as its context.
  defp children({:document, root}), do: [root]
  defp children(%__MODULE__{children: children}), do: children
  defp children(_text), do: []

  # Every descendant of `node` in document order. The walk keeps a work list
  # of nodes still to visit and conses each visited node onto an accumulator,
  # so it is linear in the size of the subtree however deeply it nests.
  defp descendants(node), do: walk(children(node), [])

  defp walk([], visited), do: Enum.reverse(visited)

  defp walk([%__MODULE__{children: children} = element | rest], visited),
    do: walk(children ++ rest, [element | visited])

  defp walk([text | rest], visited), do: walk(rest, [text | visited])

  defp matches?(text, :text), do: is_binary(text)
  defp matches?(%__MODULE__{namespace: ns, name: name}, {:name, ns, name}), do: true
  defp matches?(%__MODULE__{name: name}, {:local_name, names}), do: name in names
  defp matches?(_node, _test), do: false

  defp compile(path, namespaces) do
    {origin, rest} =
      case path do
        # `./a` reads as `/a` from the context node and `.//a` as `//a`.
        "./" <> rest -> {:context, "/" <> rest}
        "/" <> _absolute -> {:document, path}
        _relative -> {:context, "/" <> path}
      end

    steps = Regex.scan(~r{(//?)([^/]+)}, rest, capture: :all_but_first)

    unless Enum.map_join(steps, &Enum.join/1) == rest do
      unsupported!(path)
    end

    {origin,
     Enum.map(steps, fn [sep, step] -> {axis(sep), node_test(step, path, namespaces)} end)}
  end

  defp axis("/"), do: :child
  defp axis("//"), do: :descendant

  defp node_test("text()", _path, _namespaces), do: :text

  defp node_test("@" <> name, path, _namespaces) do
    if Regex.match?(~r/\A[A-Za-z_][\w.-]*\z/, name),
      do: {:attribute, name},
      else: unsupported!(path)
  end

  defp node_test("*[" <> predicate, path, _namespaces) do
    names = Regex.scan(~r/local-name\(\)\s*=\s*'([^']*)'/, predicate, capture: :all_but_first)
    rebuilt = Enum.map_join(names, " or ", fn [name] -> "local-name()='#{name}'" end) <> "]"

    if names != [] and String.replace(predicate, ~r/\s*=\s*/, "=") == rebuilt do
      {:local_name, List.flatten(names)}
    else
      unsupported!(path)
    end
  end

  defp node_test(step, path, namespaces) do
    case Regex.run(~r/\A(?:([A-Za-z_][\w.-]*):)?([A-Za-z_][\w.-]*)\z/, step,
           capture: :all_but_first
         ) do
      ["", local] -> {:name, "", local}
      [prefix, local] -> {:name, namespace_for!(prefix, namespaces, path), local}
      nil -> unsupported!(path)
    end
  end

  defp namespace_for!(prefix, namespaces, path) do
    case List.keyfind(namespaces, String.to_charlist(prefix), 0) do
      {_prefix, uri} ->
        to_string(uri)

      nil ->
        raise ArgumentError, "unbound namespace prefix #{inspect(prefix)} in #{inspect(path)}"
    end
  end

  @spec unsupported!(String.t()) :: no_return()
  defp unsupported!(path),
    do: raise(ArgumentError, "SafeXml does not support the xpath #{inspect(path)}")
end
