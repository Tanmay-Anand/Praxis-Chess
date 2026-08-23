package com.praxis.api;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

/**
 * Forwards all React Router client-side paths to index.html.
 *
 * The path regex excludes two things so they reach the resource handler and
 * the REST layer instead:
 *   - api, assets, actuator, v3 (OpenAPI), swagger-ui  (negative lookahead)
 *   - any segment containing a dot, i.e. a file name       ([^.]*)
 *
 * The dot rule matters when the frontend is served from the jar's static/
 * directory, as it is in the Docker image: without it `forward:/index.html`
 * matches this very controller again and the request forwards until Tomcat
 * gives up with a 500. Running Vite on :5173 hides that — nothing ever asks
 * this app for index.html.
 *
 * Spring MVC matches @RestController routes before this catch-all anyway,
 * but the lookahead is a second line of defence for nested routes.
 */
@Controller
public class SpaController {

    private static final String SPA_EXCLUSIONS =
            "^(?!api|assets|actuator|v3|swagger-ui)[^.]*$";

    @GetMapping("/")
    public String root() {
        return "forward:/index.html";
    }

    @GetMapping("/{path:" + SPA_EXCLUSIONS + "}")
    public String spa() {
        return "forward:/index.html";
    }

    @GetMapping("/{path:" + SPA_EXCLUSIONS + "}/**")
    public String spaDeep() {
        return "forward:/index.html";
    }
}
