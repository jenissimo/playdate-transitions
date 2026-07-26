-- Minimal host-lua assertion harness. Deliberately tiny: it must not become a
-- dependency worth learning, and it has to run under a stock `lua` with no
-- rocks installed.
local A = {}
A.count = 0
A.fails = 0

function A.eq(actual, expected, msg)
    A.count = A.count + 1
    if actual ~= expected then
        A.fails = A.fails + 1
        print(string.format("FAIL: %s (got %s, want %s)",
            msg or "?", tostring(actual), tostring(expected)))
    end
end

-- Floats: every module here computes rates, gains and easing curves, and an
-- exact-equality assert on those is a test that fails for the wrong reason.
function A.near(actual, expected, eps, msg)
    A.count = A.count + 1
    if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-6) then
        A.fails = A.fails + 1
        print(string.format("FAIL: %s (got %s, want %s +/- %s)",
            msg or "?", tostring(actual), tostring(expected), tostring(eps or 1e-6)))
    end
end

function A.truthy(v, msg) A.eq(not not v, true, msg) end
function A.falsy(v, msg)  A.eq(not not v, false, msg) end

function A.done()
    print(string.format("%d checks, %d failures", A.count, A.fails))
    if A.fails > 0 then os.exit(1) end
end

return A
