defmodule Protobuf do
  alias Protobuf.Parser
  alias Protobuf.Builder
  alias Protobuf.Config
  alias Protobuf.ConfigError
  alias Protobuf.Field
  alias Protobuf.OneOfField
  alias Protobuf.Utils

  defmacro __using__(opts) do
    config = case opts do
      << schema :: binary >> ->
        %Config{namespace: __CALLER__.module, schema: schema}
      [<< schema :: binary >>, only: only] ->
        %Config{namespace: __CALLER__.module, schema: schema, only: parse_only(only, __CALLER__)}
      [<< schema :: binary >>, inject: true] ->
        only = __CALLER__.module |> Module.split |> Enum.join(".") |> String.to_atom
        %Config{namespace: __CALLER__.module, schema: schema, only: [only], inject: true}
      [<< schema :: binary >>, only: only, inject: true] ->
        types = parse_only(only, __CALLER__)
        case types do
          []       -> raise ConfigError, error: "You must specify a type using :only when combined with inject: true"
          [_type]  -> %Config{namespace: __CALLER__.module, schema: schema, only: types, inject: true}
        end
      _ ->
        namespace = Dict.get(opts, :namespace, __CALLER__.module)
        opts = Dict.delete(opts, :namespace)
        case opts do
          from: file ->
            %Config{namespace: namespace, from_file: file}
          from: file, use_package_names: use_package_names ->
            %Config{namespace: namespace, from_file: file, use_package_names: use_package_names}
          [from: file, only: only] ->
            %Config{namespace: namespace, only: parse_only(only, __CALLER__), from_file: file}
          [from: file, inject: true] ->
            %Config{namespace: namespace,  only: [namespace], inject: true, from_file: file}
          [from: file, only: only, inject: true] ->
            types = parse_only(only, __CALLER__)
            case types do
              []       -> raise ConfigError, error: "You must specify a type using :only when combined with inject: true"
              [_type]  -> %Config{namespace: namespace, only: types, inject: true, from_file: file}
            end
        end
    end

    config |> parse(__CALLER__) |> Builder.define(config)
  end

  # Read the type or list of types to extract from the schema
  defp parse_only(only, caller) do
    {types, []} = Code.eval_quoted(only, [], caller)
    case types do
      types when is_list(types) -> types
      types when types == nil   -> []
      _                         -> [types]
    end
  end

  # Parse and fix namespaces of parsed types
  defp parse(%Config{namespace: ns, schema: schema, inject: inject, from_file: nil}, _) do
    Parser.parse_string!(schema) |> namespace_types(ns, inject)
  end
  defp parse(%Config{namespace: ns, inject: inject, from_file: file, use_package_names: use_package_names}, caller) do
    {paths, import_dirs} = resolve_paths(file, caller)
    Parser.parse_files!(paths, [imports: import_dirs, use_packages: use_package_names]) |> namespace_types(ns, inject)
  end

  # Apply namespace to top-level types
  defp namespace_types(parsed, ns, inject) do
    for {{type, name}, fields} <- parsed do
      if inject do
        {{type, :"#{name |> normalize_name}"}, namespace_fields(type, fields, ns)}
      else
        {{type, :"#{ns}.#{name |> normalize_name}"}, namespace_fields(type, fields, ns)}
      end
    end
  end

  # Apply namespace to nested types
  defp namespace_fields(:msg, fields, ns), do: Enum.map(fields, &namespace_fields(&1, ns))
  defp namespace_fields(_, fields, _),     do: fields
  defp namespace_fields(field, ns) when not is_map(field) do
    case elem(field, 0) do
      :gpb_oneof -> field |> Utils.convert_from_record(OneOfField) |> namespace_fields(ns)
      _          -> field |> Utils.convert_from_record(Field) |> namespace_fields(ns)
    end
  end
  defp namespace_fields(%Field{type: {:map, key_type, value_type}} = field, ns) do
    %{field | :type => {:map, key_type |> namespace_map_type(ns), value_type |> namespace_map_type(ns)}}
  end
  defp namespace_fields(%Field{type: {type, name}} = field, ns) do
    %{field | :type => {type, :"#{ns}.#{name |> normalize_name}"}}
  end
  defp namespace_fields(%Field{} = field, _ns) do
    field
  end
  defp namespace_fields(%OneOfField{} = field, ns) do
    field |> Map.put(:fields, Enum.map(field.fields, &namespace_fields(&1, ns)))
  end

  defp namespace_map_type({:msg, name}, ns) do
    {:msg, :"#{ns}.#{name |> normalize_name}"}
  end
  defp namespace_map_type(type, _ns) do
    type
  end

  # Normalizes module names by ensuring they are cased correctly
  # (respects camel-case and nested modules)
  defp normalize_name(name) do
    name
    |> Atom.to_string
    |> String.split(".", parts: :infinity)
    |> Enum.map(fn(x) -> String.split_at(x, 1) end)
    |> Enum.map(fn({first, remainder}) -> String.upcase(first) <> remainder end)
    |> Enum.join(".")
    |> String.to_atom
  end

  defp resolve_paths(quoted_files, caller) do
    paths = case Code.eval_quoted(quoted_files, [], caller) do
      {path, _} when is_binary(path) -> [path]
      {paths, _} when is_list(paths) -> paths
    end

    import_dirs = Enum.map(paths, &Path.dirname/1) |> Enum.uniq

    {paths, import_dirs}
  end
end
