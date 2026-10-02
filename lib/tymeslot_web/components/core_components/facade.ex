defmodule TymeslotWeb.Components.CoreComponents.Facade do
  @moduledoc """
  Builds `TymeslotWeb.Components.CoreComponents`, the one module callers import
  or alias for the shared components, from the submodules that implement them.

  `expose/2` reads a submodule's own component declarations
  (`__components__/0`) at compile time and gives `CoreComponents` a function of
  the same name with the same `attr` and `slot` declarations, delegating to the
  submodule. A component's attributes are therefore written once, beside its
  markup, and a caller writing `<.pill tone={:nope}>` or
  `<CoreComponents.pill tone={:nope}>` is still checked at compile time against
  them. Hand-written delegates used to restate every declaration, and a
  restatement that fell behind its component silently rejected the difference.
  """

  alias Phoenix.Component.Declarative

  @doc """
  Exposes each of `names`, function components of `module`, on the calling
  module, recording each in its accumulated `@exposed_component` attribute.
  """
  defmacro expose(module, names) do
    # `def` written in this module's quote would be `Kernel.def`, which never
    # registers the declarations above it; the component `def` that
    # `use Phoenix.Component` imports does.
    module = Macro.expand(module, __CALLER__)
    components = module.__components__()

    for name <- names do
      %{attrs: attrs, slots: slots} =
        Map.get(components, name) ||
          raise ArgumentError, "#{inspect(module)} declares no component #{inspect(name)}"

      quote do
        @exposed_component {unquote(name), unquote(module)}
        unquote_splicing(Enum.map(attrs, &attr_ast/1))
        unquote_splicing(Enum.map(slots, &slot_ast/1))
        @doc "See `#{unquote(inspect(module))}.#{unquote(name)}/1`."
        @spec unquote(name)(map()) :: Phoenix.LiveView.Rendered.t()
        Declarative.def(unquote(name)(assigns),
          do: unquote(module).unquote(name)(assigns)
        )
      end
    end
  end

  defp attr_ast(%{name: name, type: type, opts: opts, required: required, doc: doc}) do
    opts = opts |> put_required(required) |> put_doc(doc)

    quote do
      attr unquote(name), unquote(Macro.escape(declared_type(type))), unquote(Macro.escape(opts))
    end
  end

  defp slot_ast(%{name: name, opts: opts, required: required, doc: doc, attrs: []}) do
    opts = opts |> put_required(required) |> put_doc(doc)

    quote do
      slot unquote(name), unquote(Macro.escape(opts))
    end
  end

  defp slot_ast(%{name: name, opts: opts, required: required, doc: doc, attrs: attrs}) do
    opts = opts |> put_required(required) |> put_doc(doc)

    quote do
      slot unquote(name), unquote(Macro.escape(opts)) do
        (unquote_splicing(Enum.map(attrs, &attr_ast/1)))
      end
    end
  end

  # `__components__/0` records a struct type as `{:struct, module}`; `attr`
  # takes the bare module.
  defp declared_type({:struct, module}), do: module
  defp declared_type(type), do: type

  defp put_required(opts, true), do: Keyword.put(opts, :required, true)
  defp put_required(opts, false), do: opts

  defp put_doc(opts, nil), do: opts
  defp put_doc(opts, doc), do: Keyword.put(opts, :doc, doc)
end
