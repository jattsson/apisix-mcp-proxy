package fixture;

import io.modelcontextprotocol.common.McpTransportContext;
import io.modelcontextprotocol.server.McpStatelessServerHandler;
import io.modelcontextprotocol.server.transport.HttpServletStatelessServerTransport;
import io.modelcontextprotocol.spec.McpSchema;
import org.apache.catalina.Context;
import org.apache.catalina.startup.Tomcat;
import reactor.core.publisher.Mono;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** A real Java SDK Streamable HTTP transport with deterministic test use cases. */
public final class Fixture {
    private static final String NAME = System.getenv().getOrDefault("FIXTURE_NAME", "java-a");

    public static void main(String[] args) throws Exception {
        HttpServletStatelessServerTransport transport = HttpServletStatelessServerTransport.builder()
                .messageEndpoint("/mcp").build();
        transport.setMcpHandler(new McpStatelessServerHandler() {
            @Override
            public Mono<McpSchema.JSONRPCResponse> handleRequest(McpTransportContext context,
                    McpSchema.JSONRPCRequest request) {
                Object result = response(request);
                return Mono.just(new McpSchema.JSONRPCResponse("2.0", request.id(), result, null));
            }

            @Override
            public Mono<Void> handleNotification(McpTransportContext context,
                    McpSchema.JSONRPCNotification notification) {
                return Mono.empty();
            }
        });
        Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir("/tmp/tomcat");
        tomcat.setPort(8080);
        tomcat.getConnector();
        Context context = tomcat.addContext("", "/tmp");
        Tomcat.addServlet(context, "mcp", transport);
        context.addServletMappingDecoded("/mcp", "mcp");
        tomcat.start();
        tomcat.getServer().await();
    }

    private static Object response(McpSchema.JSONRPCRequest request) {
        Map<?, ?> params = request.params() instanceof Map<?, ?> map ? map : Map.of();
        return switch (request.method()) {
            case "initialize" -> Map.of("protocolVersion", "2025-11-25", "serverInfo",
                    Map.of("name", NAME, "version", "1.0.0"), "capabilities",
                    Map.of("tools", Map.of(), "prompts", Map.of(), "resources", Map.of()),
                    "instructions", "Read-only fixture " + NAME);
            case "tools/list" -> {
                String name = params.containsKey("cursor") ? "second" : "echo";
                Map<String, Object> result = new LinkedHashMap<>();
                result.put("tools", List.of(Map.of("name", name, "inputSchema",
                        Map.of("type", "object", "properties", Map.of(), "required", List.of()),
                        "annotations", Map.of("readOnlyHint", true))));
                if (!params.containsKey("cursor")) {
                    result.put("nextCursor", "second-page");
                }
                yield result;
            }
            case "prompts/list" -> Map.of("prompts", List.of(Map.of("name", "prompt", "arguments", List.of())));
            case "resources/list" -> Map.of("resources", List.of(Map.of("name", "resource", "uri", "fixture://" + NAME + "/one")));
            case "resources/templates/list" -> Map.of("resourceTemplates", List.of(Map.of("name", "template", "uriTemplate", "fixture://" + NAME + "/{id}")));
            case "prompts/get" -> Map.of("messages", List.of(Map.of("role", "user", "content", Map.of("type", "text", "text", NAME))));
            case "resources/read" -> Map.of("contents", List.of(Map.of("uri", params.get("uri"), "text", NAME)));
            default -> {
                Map<String, Object> structured = new LinkedHashMap<>();
                structured.put("fixture", NAME);
                structured.put("arguments", params.get("arguments"));
                structured.put("null", null);
                structured.put("false", false);
                structured.put("zero", 0);
                structured.put("array", new ArrayList<>());
                structured.put("object", new LinkedHashMap<>());
                yield Map.of("content", List.of(), "structuredContent", structured, "isError", false);
            }
        };
    }
}
