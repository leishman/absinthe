defmodule Absinthe.Schema.Compiled do
  @moduledoc false

  @behaviour Absinthe.Schema.Provider

  def pipeline(pipeline) do
    pipeline
  end

  def __absinthe_type__(schema_mod, name) do
    compiled(schema_mod).__absinthe_type__(name)
  end

  def __absinthe_directive__(schema_mod, name) do
    compiled(schema_mod).__absinthe_directive__(name)
  end

  def __absinthe_types__(schema_mod) do
    compiled(schema_mod).__absinthe_types__()
  end

  def __absinthe_types__(schema_mod, group) do
    compiled(schema_mod).__absinthe_types__(group)
  end

  def __absinthe_directives__(schema_mod) do
    compiled(schema_mod).__absinthe_directives__()
  end

  def __absinthe_interface_implementors__(schema_mod) do
    compiled(schema_mod).__absinthe_interface_implementors__()
  end

  def __absinthe_schema_declaration__(schema_mod) do
    compiled(schema_mod).__absinthe_schema_declaration__()
  end

  # Type lookups happen hundreds of times per request. Module.concat/1 builds
  # the module name and interns it in the atom table on every call, which
  # made it one of the most expensive parts of document processing, so the
  # name is computed once per schema and cached in :persistent_term.
  defp compiled(schema_mod) do
    key = {__MODULE__, schema_mod}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = Module.concat([schema_mod, Compiled])
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end
end
