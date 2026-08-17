import { serve } from "../_shared/http.ts";
import { handleOperation } from "../_shared/operations.ts";

serve((request) => handleOperation("delivery-quote", request));
