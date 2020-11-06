import Foundation

public func buildASTSchema(_ document: Document) throws -> GraphQLSchema {

    var schemaDefinition: SchemaDefinition? = nil
    var typeDefinitions: [TypeDefinition] = []
    var directiveDefinitions: [DirectiveDefinition] = []

    for definition in document.definitions {
        switch definition {
        case let schema as SchemaDefinition:
            schemaDefinition = schema
        case let type as TypeDefinition:
            typeDefinitions.append(type)
        case let directive as DirectiveDefinition:
            directiveDefinitions.append(directive)
        default:
            print("Warning: Unknown handled definition: \(definition)")
            break
        }
    }

    let typeDefinitionMap: [String: TypeDefinition] = document.definitions.reduce(into: [:]) { map, definition in
        if let typeDefinition = definition as? TypeDefinition {
            map[typeDefinition.name.value] = typeDefinition
        }
    }

    let standardTypes = [
        GraphQLString,
        GraphQLInt,
        GraphQLFloat,
        GraphQLBoolean,
        GraphQLID,
    ]

    var builtTypes: [String: GraphQLNamedType] = [:]
    standardTypes.forEach {
        builtTypes[$0.name] = $0
    }

    func resolveInputType(_ type: Type) throws -> GraphQLInputType {
        switch type {
        case let list as ListType:
            return try GraphQLList(resolveInputType(list.type))
        case let nonnull as NonNullType:
            return try GraphQLNonNull(resolveInputType(nonnull.type) as! GraphQLNullableType)
        case let named as NamedType:
            return try resolveNamedType(named.name.value) as! GraphQLInputType
        default:
            fatalError("Unknown type: \(type)")
        }
    }

    func resolveOutputType(_ type: Type) throws -> GraphQLOutputType {
        switch type {
        case let list as ListType:
            return GraphQLList(try resolveOutputType(list.type))
        case let nonnull as NonNullType:
            return GraphQLNonNull(try resolveOutputType(nonnull.type) as! GraphQLNullableType)
        case let named as NamedType:
            if let builtType = builtTypes[named.name.value] as? GraphQLOutputType {
                // Use the existing type if it has already been built
                return builtType
            } else {
                // Other return a type reference to avoid circular dependencies.
                return GraphQLTypeReference(named.name.value)
            }
        default:
            fatalError("Unknown type: \(type)")
        }
    }

    func resolveNamedType(_ name: String) throws -> GraphQLNamedType {
        if let builtType = builtTypes[name] {
            return builtType
        }
        guard let typeDefinition = typeDefinitionMap[name] else {
            fatalError("Unknown type: \(name)")
        }
        let newType = try buildType(
            typeDefinition,
            objectTypeResolver: { (namedType) throws -> GraphQLObjectType in
                guard let object = try resolveNamedType(namedType.name.value) as? GraphQLObjectType else {
                    fatalError("Expected object, but found non-object type \(namedType.name.value)")
                }
                return object
            },
            interfaceTypeResolver: { (namedType) throws -> GraphQLInterfaceType in
                guard let interface = try resolveNamedType(namedType.name.value) as? GraphQLInterfaceType else {
                    fatalError("Expected interface, but found non-object type \(namedType.name.value)")
                }
                return interface
            },
            outputTypeResolver: resolveOutputType(_:),
            inputTypeResolver: resolveInputType(_:)
        )
        builtTypes[newType.name] = newType
        return newType
    }

    let query = schemaDefinition!.operationTypes.first { $0.operation == .query }!
    let mutation = schemaDefinition!.operationTypes.first { $0.operation == .mutation }
    let subscription = schemaDefinition!.operationTypes.first { $0.operation == .mutation }

    return try GraphQLSchema(
        query: resolveNamedType(query.type.name.value) as! GraphQLObjectType,
        mutation: mutation.map { try resolveNamedType($0.type.name.value) as! GraphQLObjectType },
        subscription: subscription.map { try resolveNamedType($0.type.name.value) as! GraphQLObjectType },
        types: typeDefinitions.map { try resolveNamedType($0.name.value) },
        directives: directiveDefinitions.map { try buildDirective($0, inputTypeResolver: resolveInputType(_:)) }
    )
}

/**
 * A helper function to build a GraphQLSchema directly from a source document.
 */
public func buildSchema(source: Source) throws -> GraphQLSchema {
    let document = try parse(source: source)
    return try buildASTSchema(document)
}

/**
 * A helper function to build a GraphQLSchema directly from a source document.
 */
public func buildSchema(source: String) throws -> GraphQLSchema {
    return try buildSchema(source: Source(body: source))
}

func buildDirective(_ node: DirectiveDefinition, inputTypeResolver: (Type) throws -> GraphQLInputType) throws -> GraphQLDirective {
    return try GraphQLDirective(
        name: node.name.value,
        description: node.description?.value ?? "",
        locations: node.locations.map { DirectiveLocation(rawValue: $0.value)! },
        args: buildArgumentMap(node.arguments, typeResolver: inputTypeResolver)
    )
}

func buildFieldMap<Node: HasFields>(_ node: Node, outputTypeResolver: (Type) throws -> GraphQLOutputType, inputTypeResolver: (Type) throws -> GraphQLInputType) throws -> GraphQLFieldMap {
    return try node.fields.reduce(into: [:]) { (map, node) in
        map[node.name.value] = GraphQLField(
            type: try outputTypeResolver(node.type),
            description: node.description?.value,
            deprecationReason: getDeprecationReason(node),
            args: try buildArgumentMap(node.arguments, typeResolver: inputTypeResolver)
        )
    }
}

func buildArgumentMap(_ nodes: [InputValueDefinition], typeResolver: (Type) throws -> GraphQLInputType) throws -> GraphQLArgumentConfigMap {
    return try nodes.reduce(into: [:]) { (map, node) in
        let type = try typeResolver(node.type)
        // TODO This probably doesn't work
        let defaultValue = try valueFromAST(valueAST: node.defaultValue, type: type)
        map[node.name.value] = GraphQLArgument(
            type: type,
            description: node.description?.value,
            defaultValue: defaultValue
        )
    }
}

func buildInputFieldMap(_ node: InputObjectTypeDefinition, typeResolveer: (Type) throws -> GraphQLInputType) throws -> InputObjectConfigFieldMap {
    return try node.fields.reduce(into: [:]) { (map, node) in
        let type = try typeResolveer(node.type)
        // TODO This probably doesn't work
        let defaultValue = try valueFromAST(valueAST: node.defaultValue, type: type)
        map[node.name.value] = InputObjectField(
            type: type,
            defaultValue: defaultValue,
            description: node.description?.value
        )
    }
}

func buildEnumValueMap(_ node: EnumTypeDefinition) -> GraphQLEnumValueMap {
    return node.values.reduce(into: [:], { map, node in
        map[node.name.value] = GraphQLEnumValue(
            value: .string(node.name.value),
            description: node.description?.value,
            deprecationReason: getDeprecationReason(node))
    })
}

func buildUnionTypes(_ node: UnionTypeDefinition, objectResolver: (NamedType) throws -> GraphQLObjectType) throws -> [GraphQLObjectType] {
    return try node.types.map { try objectResolver($0) }
}

func buildType(
    _ node: TypeDefinition,
    objectTypeResolver: (NamedType) throws -> GraphQLObjectType,
    interfaceTypeResolver: (NamedType) throws -> GraphQLInterfaceType,
    outputTypeResolver: (Type) throws -> GraphQLOutputType,
    inputTypeResolver: (Type) throws -> GraphQLInputType
) throws -> GraphQLNamedType {
    switch node {
    case let scalar as ScalarTypeDefinition:
        return try GraphQLScalarType(
            name: scalar.name.value,
            description: scalar.description?.value,
            serialize: { _ in fatalError("Serialization not supported for client schema")}
        )
    case let object as ObjectTypeDefinition:
        return try GraphQLObjectType(
            name: object.name.value,
            description: object.description?.value,
            fields: buildFieldMap(
                object,
                outputTypeResolver: outputTypeResolver,
                inputTypeResolver: inputTypeResolver
            ),
            interfaces: object.interfaces.map { try interfaceTypeResolver($0) },
            isTypeOf: { _, _, _ in fatalError("isTypeOf not supported for client schema")}
        )
    case let interface as InterfaceTypeDefinition:
        return try GraphQLInterfaceType(
            name: interface.name.value,
            description: interface.description?.value,
            interfaces: interface.interfaces.map { try interfaceTypeResolver($0) },
            fields: buildFieldMap(
                interface,
                outputTypeResolver: outputTypeResolver,
                inputTypeResolver: inputTypeResolver
            ),
            resolveType: nil
        )
    case let union as UnionTypeDefinition:
        return try GraphQLUnionType(
            name: union.name.value,
            description: union.description?.value,
            resolveType: { (_, _, _) -> TypeResolveResultRepresentable in
                fatalError("Resolving types not supported for client schema")
            },
            types: buildUnionTypes(union, objectResolver: objectTypeResolver)
        )
    case let `enum` as EnumTypeDefinition:
        return try GraphQLEnumType(
            name: `enum`.name.value,
            description: `enum`.description?.value,
            values: buildEnumValueMap(`enum`)
        )
    case let inputObject as InputObjectTypeDefinition:
        return try GraphQLInputObjectType(
            name: inputObject.name.value,
            description: inputObject.description?.value,
            fields: buildInputFieldMap(inputObject, typeResolveer: inputTypeResolver)
        )
    default:
        fatalError("Unknown definition type: \(node)")
    }
}

// MARK: - Helpers

protocol HasDirectives {
    var directives: [Directive] { get }
}
extension FieldDefinition: HasDirectives {}
extension EnumValueDefinition: HasDirectives {}

protocol HasFields {
    var fields: [FieldDefinition] { get }
}
extension ObjectTypeDefinition: HasFields {}
extension InterfaceTypeDefinition: HasFields {}

func getDeprecationReason<Node: HasDirectives>(_ node: Node) -> String? {
    if let directive = node.directives.first(where: { $0.name.value == GraphQLDeprecatedDirective.name}),
       let reason = directive.arguments.first(where: { $0.name.value == "reason" }) {
        return (reason.value as? StringValue)?.value
    }

    return nil
}

extension TypeDefinition {
    var name: Name {
        switch self {
        case let scalar as ScalarTypeDefinition:
            return scalar.name
        case let object as ObjectTypeDefinition:
            return object.name
        case let interface as InterfaceTypeDefinition:
            return interface.name
        case let union as UnionTypeDefinition:
            return union.name
        case let `enum` as EnumTypeDefinition:
            return `enum`.name
        case let inputObject as InputObjectTypeDefinition:
            return inputObject.name
        default:
            fatalError("Unknown definition type: \(self)")
        }
    }
}
