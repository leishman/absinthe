defmodule Absinthe.Blueprint.TransformTest.Reference do
  # The previous (generic) implementation of Absinthe.Blueprint.Transform,
  # used as an oracle. Defined before the test module because ExUnit may
  # start running an async test module before the rest of its file compiles.
  alias Absinthe.Blueprint

  def prewalk(node, fun) when is_function(fun, 1) do
    {node, _} =
      prewalk(node, nil, fn x, nil ->
        case fun.(x) do
          {:halt, x} -> {:halt, x, nil}
          x -> {x, nil}
        end
      end)

    node
  end

  def prewalk(node, acc, fun) when is_function(fun, 2), do: walk(node, acc, fun, &pass/2)

  def postwalk(node, fun) when is_function(fun, 1) do
    {node, _} = postwalk(node, nil, fn x, nil -> {fun.(x), nil} end)
    node
  end

  def postwalk(node, acc, fun) when is_function(fun, 2), do: walk(node, acc, &pass/2, fun)

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

  @doc false
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
    Enum.map_reduce(nodes, acc, &walk(&1, &2, pre, post))
  end

  def walk(node, acc, pre, post) do
    {node, acc} =
      case pre.(node, acc) do
        {:halt, node, acc} ->
          {node, acc}

        {node, acc} ->
          maybe_walk_children(node, acc, pre, post)
      end

    post.(node, acc)
  end

  for {node_name, children} <- nodes_with_children do
    def maybe_walk_children(%unquote(node_name){} = node, acc, pre, post) do
      node_with_children(node, unquote(children), acc, pre, post)
    end
  end

  def maybe_walk_children(node, acc, _, _) do
    {node, acc}
  end

  defp node_with_children(node, children, acc, pre, post) do
    walk_children(node, children, acc, pre, post)
  end

  defp walk_children(node, children, acc, pre, post) do
    Enum.reduce(children, {node, acc}, fn child_key, {node, acc} ->
      {children, acc} =
        node
        |> Map.fetch!(child_key)
        |> walk(acc, pre, post)

      {Map.put(node, child_key, children), acc}
    end)
  end
end

defmodule Absinthe.Blueprint.TransformTest do
  use Absinthe.Case, async: true

  alias Absinthe.{Blueprint, Phase, Pipeline}
  alias Absinthe.Blueprint.Transform
  alias __MODULE__.Reference

  @documents [
    """
    query Q($id: ID!, $cmd: DogCommand = SIT, $skip: Boolean = false) {
      human(id: $id) @skip(if: $skip) {
        name
        ...HumanFields
        pets { ... on Dog { name barkVolume } ... on Cat { meowVolume } }
      }
      dog { doesKnowCommand(dogCommand: $cmd) isHousetrained(atOtherHomes: true) }
      complicatedArgs {
        complexArgField(complexArg: {requiredField: true, intField: 4, stringListField: ["a", "b"]})
        complexArgList: complexArgField(complexArgList: [{requiredField: false}, {requiredField: true}])
      }
    }

    fragment HumanFields on Human {
      relatives { name @include(if: true) }
      catOrDog { __typename ... on Dog { name } }
    }
    """,
    """
    mutation { createDog(name: "Rex") { name } }
    query Other { pet { name } } subscription S { __typename }
    """,
    "{ unknownField(arg: [[1, 2], {a: null}]) { ... on Nope { x } } }"
  ]

  @phases [
    Phase.Blueprint,
    Phase.Schema,
    Phase.Document.Arguments.Parse,
    Phase.Document.Validation.Result
  ]

  defp blueprints do
    documents =
      for doc <- @documents, phase <- @phases do
        pipeline =
          Absinthe.Fixtures.PetsSchema
          |> Pipeline.for_document(jump_phases: false)
          |> Pipeline.upto(phase)

        case Pipeline.run(doc, pipeline) do
          {:ok, bp, _} -> bp
          {:error, %Blueprint{} = bp, _} -> bp
        end
      end

    schemas = [
      Absinthe.Fixtures.PetsSchema.__absinthe_blueprint__(),
      Absinthe.Fixtures.ContactSchema.__absinthe_blueprint__()
    ]

    documents ++ schemas
  end

  # Visitors record what they see (in order) and modify nodes, so both the
  # traversal order and the rebuilt tree are compared.
  defp summary(%struct{} = node), do: {struct, :erlang.phash2(node)}
  defp summary(other), do: {:term, :erlang.phash2(other)}

  defp mark(%{flags: flags} = node) when is_map(flags),
    do: %{node | flags: Map.put(flags, :seen, true)}

  defp mark(node), do: node

  defp halt?(%Blueprint.Document.Fragment.Inline{}), do: true
  defp halt?(%Blueprint.Schema.EnumTypeDefinition{}), do: true
  defp halt?(_), do: false

  defp record(node) do
    Process.put(:trail, [summary(node) | Process.get(:trail, [])])
  end

  defp with_trail(fun) do
    Process.put(:trail, [])
    result = fun.()
    {result, Process.delete(:trail)}
  end

  defp pre1(node) do
    record(node)
    if halt?(node), do: {:halt, mark(node)}, else: mark(node)
  end

  defp post1(node) do
    record(node)
    mark(node)
  end

  defp pre2(node, acc) do
    if halt?(node),
      do: {:halt, mark(node), [summary(node) | acc]},
      else: {mark(node), [summary(node) | acc]}
  end

  defp post2(node, acc), do: {mark(node), [summary(node) | acc]}

  test "prewalk/2 matches the reference implementation" do
    for bp <- blueprints() do
      assert with_trail(fn -> Transform.prewalk(bp, &pre1/1) end) ==
               with_trail(fn -> Reference.prewalk(bp, &pre1/1) end)
    end
  end

  test "postwalk/2 matches the reference implementation" do
    for bp <- blueprints() do
      assert with_trail(fn -> Transform.postwalk(bp, &post1/1) end) ==
               with_trail(fn -> Reference.postwalk(bp, &post1/1) end)
    end
  end

  test "prewalk/3 matches the reference implementation" do
    for bp <- blueprints() do
      assert Transform.prewalk(bp, [], &pre2/2) == Reference.prewalk(bp, [], &pre2/2)
    end
  end

  test "postwalk/3 matches the reference implementation" do
    for bp <- blueprints() do
      assert Transform.postwalk(bp, [], &post2/2) == Reference.postwalk(bp, [], &post2/2)
    end
  end

  test "walk/4 matches the reference implementation" do
    pre = fn node, acc -> pre2(node, [:pre | acc]) end
    post = fn node, acc -> post2(node, [:post | acc]) end

    for bp <- blueprints() do
      assert Transform.walk(bp, [], pre, post) == Reference.walk(bp, [], pre, post)
    end
  end

  test "walks bare lists and non-blueprint values" do
    for value <- [[], [nil, 1, [%Blueprint.Input.Null{}]], :atom, %{a: 1}] do
      assert Transform.prewalk(value, [], &pre2/2) == Reference.prewalk(value, [], &pre2/2)
      assert Transform.postwalk(value, [], &post2/2) == Reference.postwalk(value, [], &post2/2)
    end
  end
end
