defmodule Absinthe.Blueprint.Transform do
  @moduledoc false

  alias Absinthe.Blueprint

  # Tree traversal is the single most frequent operation in the document
  # pipeline: most phases walk the whole blueprint at least once. So:
  #
  #   * prewalk/2 and postwalk/2, by far the most used, get their own walkers
  #     rather than going through walk/4, so they don't allocate an
  #     accumulator tuple or call a no-op callback for every node.
  #   * Child traversal is generated per node type: all children are
  #     destructured and written back with a single struct update.
  #
  # Semantics are those of `walk/4`: `pre` is called on a node before its
  # children, `post` after them (and also after a `:halt`), every child value
  # is visited (including `nil` and other non-struct values), list elements
  # are visited in order, and the children of a node are visited in the order
  # listed below.

  @doc """
  Apply `fun` to a node, then walk to its children and do the same
  """
  @spec prewalk(
          Blueprint.node_t(),
          (Blueprint.node_t() -> Blueprint.node_t() | {:halt, Blueprint.node_t()})
        ) :: Blueprint.node_t()
  def prewalk(node, fun) when is_function(fun, 1) do
    pre(node, fun)
  end

  @doc """
  Same as `prewalk/2` but takes and returns an accumulator

  The supplied function must be arity 2.
  """
  @spec prewalk(
          Blueprint.node_t(),
          acc,
          (Blueprint.node_t(), acc ->
             {Blueprint.node_t(), acc} | {:halt, Blueprint.node_t(), acc})
        ) :: {Blueprint.node_t(), acc}
        when acc: var
  def prewalk(node, acc, fun) when is_function(fun, 2) do
    walk(node, acc, fun, &pass/2)
  end

  @doc """
  Apply `fun` to all children of a node, then apply `fun` to node
  """
  @spec postwalk(Blueprint.node_t(), (Blueprint.node_t() -> Blueprint.node_t())) ::
          Blueprint.node_t()
  def postwalk(node, fun) when is_function(fun, 1) do
    post(node, fun)
  end

  @doc """
  Same as `postwalk/2` but takes and returns an accumulator
  """
  @spec postwalk(Blueprint.node_t(), acc, (Blueprint.node_t(), acc -> {Blueprint.node_t(), acc})) ::
          {Blueprint.node_t(), acc}
        when acc: var
  def postwalk(node, acc, fun) when is_function(fun, 2) do
    walk(node, acc, &pass/2, fun)
  end

  defp pass(x, acc), do: {x, acc}

  nodes_with_children = %{
    Blueprint => [:fragments, :operations, :schema_definitions, :directives],
    Blueprint.Directive => [:arguments],
    Blueprint.Document.Field => [:selections, :arguments, :directives],
    Blueprint.Document.Operation => [:selections, :variable_definitions, :directives],
    Blueprint.TypeReference.List => [:of_type],
    Blueprint.TypeReference.NonNull => [:of_type],
    Blueprint.Document.Fragment.Inline => [:selections, :directives],
    Blueprint.Document.Fragment.Named => [:selections, :directives],
    Blueprint.Document.Fragment.Spread => [:directives],
    Blueprint.Document.VariableDefinition => [:type, :default_value, :directives],
    Blueprint.Input.Argument => [:input_value],
    Blueprint.Input.Field => [:input_value],
    Blueprint.Input.Object => [:fields],
    Blueprint.Input.List => [:items],
    Blueprint.Input.RawValue => [:content],
    Blueprint.Input.Value => [:normalized],
    Blueprint.Schema.DirectiveDefinition => [:directives, :arguments],
    Blueprint.Schema.EnumTypeDefinition => [:directives, :values],
    Blueprint.Schema.EnumValueDefinition => [:directives],
    Blueprint.Schema.FieldDefinition => [:type, :arguments, :directives],
    Blueprint.Schema.InputObjectTypeDefinition => [:fields, :directives],
    Blueprint.Schema.InputValueDefinition => [:type, :default_value, :directives],
    Blueprint.Schema.InterfaceTypeDefinition => [:interfaces, :fields, :directives],
    Blueprint.Schema.ObjectTypeDefinition => [:interfaces, :fields, :directives],
    Blueprint.Schema.ScalarTypeDefinition => [:directives],
    Blueprint.Schema.SchemaDeclaration => [:directives, :field_definitions],
    Blueprint.Schema.SchemaDefinition => [
      :directive_definitions,
      :type_definitions,
      :type_extensions,
      :directives,
      :schema_declaration
    ],
    Blueprint.Schema.TypeExtensionDefinition => [:definition],
    Blueprint.Schema.UnionTypeDefinition => [:directives, :types]
  }

  @spec walk(
          Blueprint.node_t(),
          acc,
          (Blueprint.node_t(), acc ->
             {Blueprint.node_t(), acc} | {:halt, Blueprint.node_t(), acc}),
          (Blueprint.node_t(), acc -> {Blueprint.node_t(), acc})
        ) :: {Blueprint.node_t(), acc}
        when acc: var
  def walk(blueprint, acc, pre, post)

  def walk(nodes, acc, pre, post) when is_list(nodes) do
    walk_list(nodes, acc, pre, post)
  end

  def walk(node, acc, pre, post) do
    {node, acc} =
      case pre.(node, acc) do
        {:halt, node, acc} ->
          {node, acc}

        {node, acc} ->
          walk_children(node, acc, pre, post)
      end

    post.(node, acc)
  end

  defp walk_list([], acc, _pre, _post), do: {[], acc}

  defp walk_list([node | rest], acc, pre, post) do
    {node, acc} = walk(node, acc, pre, post)
    {rest, acc} = walk_list(rest, acc, pre, post)
    {[node | rest], acc}
  end

  # prewalk/2

  defp pre(nodes, fun) when is_list(nodes), do: pre_list(nodes, fun)

  defp pre(node, fun) do
    case fun.(node) do
      {:halt, node} -> node
      node -> pre_children(node, fun)
    end
  end

  defp pre_list([], _fun), do: []
  defp pre_list([node | rest], fun), do: [pre(node, fun) | pre_list(rest, fun)]

  # postwalk/2

  defp post(nodes, fun) when is_list(nodes), do: post_list(nodes, fun)
  defp post(node, fun), do: fun.(post_children(node, fun))

  defp post_list([], _fun), do: []
  defp post_list([node | rest], fun), do: [post(node, fun) | post_list(rest, fun)]

  # Per node type child traversal. For a node type with children [:a, :b]
  # this generates, for each walker, a clause like:
  #
  #     defp pre_children(%Type{a: a, b: b} = node, fun) do
  #       a = pre(a, fun)
  #       b = pre(b, fun)
  #       %{node | a: a, b: b}
  #     end

  for {node_name, children} <- nodes_with_children do
    vars = Enum.map(children, &Macro.var(&1, __MODULE__))
    pairs = Enum.zip(children, vars)
    acc = Macro.var(:acc, __MODULE__)
    fun = Macro.var(:fun, __MODULE__)
    pre = Macro.var(:pre, __MODULE__)
    post = Macro.var(:post, __MODULE__)

    walk_steps = fn call ->
      Enum.map(vars, fn var -> quote(do: unquote(var) = unquote(call.(var))) end)
    end

    defp pre_children(%unquote(node_name){unquote_splicing(pairs)} = node, unquote(fun)) do
      unquote_splicing(walk_steps.(fn v -> quote(do: pre(unquote(v), unquote(fun))) end))
      %{node | unquote_splicing(pairs)}
    end

    defp post_children(%unquote(node_name){unquote_splicing(pairs)} = node, unquote(fun)) do
      unquote_splicing(walk_steps.(fn v -> quote(do: post(unquote(v), unquote(fun))) end))
      %{node | unquote_splicing(pairs)}
    end

    defp walk_children(
           %unquote(node_name){unquote_splicing(pairs)} = node,
           unquote(acc),
           unquote(pre),
           unquote(post)
         ) do
      unquote_splicing(
        Enum.map(vars, fn v ->
          quote do
            {unquote(v), unquote(acc)} =
              walk(unquote(v), unquote(acc), unquote(pre), unquote(post))
          end
        end)
      )

      {%{node | unquote_splicing(pairs)}, unquote(acc)}
    end
  end

  defp pre_children(node, _fun), do: node
  defp post_children(node, _fun), do: node
  defp walk_children(node, acc, _pre, _post), do: {node, acc}
end
