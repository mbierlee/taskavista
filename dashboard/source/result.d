/**
 * Taskavista
 *
 * A value or the error that stood in its way, returned where failing is expected.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module result;

/**
 * A value, or the error that stood in its way.
 *
 * Returned instead of throwing where failing is an expected outcome, so the caller has to
 * deal with it. The error is a message by default; a caller that needs to tell errors
 * apart, such as by answering each with a status code of its own, can use a type of its own
 * for it, such as an enum.
 */
class Result(T, E = string)
{
    private bool success;
    private T _value;
    private E _error;

    private this(bool success, T value, E error)
    {
        this.success = success;
        this._value = value;
        this._error = error;
    }

    /// Returns: Whether the result has a value.
    bool isSuccessful() const
    {
        return success;
    }

    /// Returns: Whether the result has an error instead of a value.
    bool isFailure() const
    {
        return !success;
    }

    /// Returns: The value of the result. Only to be called on a successful result.
    T value()
    {
        assert(success,
            "Result is not successful and should not be accessed. Make sure to check isSuccessful() first.");
        return _value;
    }

    /// Returns: The error of the result. Only to be called on a failed result.
    E error()
    {
        assert(!success,
            "Result is successful so it does not have an error. Make sure to check isSuccessful() first.");
        return _error;
    }
}

/**
 * Creates a successful result.
 *
 * Params:
 *   E = The type of the error the result would have had. A message when left out.
 *   T = The type of the value.
 *   value = The value to return.
 *
 * Returns: A successful result with that value.
 */
Result!(T, E) success(E = string, T)(T value) if (!is(T == void))
{
    return new Result!(T, E)(true, value, E.init);
}

/**
 * Creates a failed result.
 *
 * Params:
 *   T = The type of the value. Even though the result has none, a type is still required.
 *   E = The type of the error.
 *   error = Why there is no value.
 *
 * Returns: A failed result with that error.
 */
Result!(T, E) failure(T, E)(E error) if (!is(T == void))
{
    return new Result!(T, E)(false, T.init, error);
}

unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    enum Error
    {
        missing,
        broken
    }

    auto answer = success(42);
    static assert(is(typeof(answer) == Result!(int, string)));
    assert(answer.isSuccessful && !answer.isFailure);
    assert(answer.value == 42);
    assertThrown!AssertError(answer.error);

    auto none = failure!int("Something went wrong");
    assert(none.isFailure && !none.isSuccessful);
    assert(none.error == "Something went wrong");
    assertThrown!AssertError(none.value);

    assert(failure!Object("Gone").error == "Gone");

    auto typed = success!Error(42);
    static assert(is(typeof(typed) == Result!(int, Error)));
    assert(typed.value == 42);

    auto broken = failure!int(Error.broken);
    static assert(is(typeof(broken) == Result!(int, Error)));
    assert(broken.error == Error.broken);
}

/**
 * Calls onSuccess with the result's value when the result is successful, and does
 * nothing when it is a failure.
 *
 * Params:
 *   T = The type of the result's value.
 *   E = The type of the result's error.
 *   Fn = The type of the callable action.
 *   res = The result to check.
 *   onSuccess = The action to call with the result's value on success.
 */
void withResult(T, E, Fn)(Result!(T, E) res, scope Fn onSuccess) if (!is(T == void))
{
    if (res.isSuccessful)
    {
        onSuccess(res.value);
    }
}

/**
 * Calls onSuccess with the result's value when the result is successful, or onError
 * with its error when it is a failure.
 *
 * Params:
 *   T = The type of the result's value.
 *   E = The type of the result's error.
 *   Fn = The type of the callable action.
 *   ErrFn = The type of the callable error action.
 *   res = The result to check.
 *   onSuccess = The action to call with the result's value on success.
 *   onError = The action to call with the error on failure.
 */
void withResult(T, E, Fn, ErrFn)(Result!(T, E) res, scope Fn onSuccess, scope ErrFn onError)
        if (!is(T == void))
{
    if (res.isSuccessful)
    {
        onSuccess(res.value);
    }
    else
    {
        onError(res.error);
    }
}

unittest
{
    int received;
    success(42).withResult((int value) { received = value; });
    assert(received == 42);

    bool called;
    failure!int("Something went wrong").withResult((int value) { called = true; });
    assert(!called);

    string error;
    success(42).withResult((int value) { received = value + 1; }, (string message) { error = message; });
    assert(received == 43 && error is null);

    received = 0;
    failure!int("Something went wrong").withResult((int value) { received = value; },
        (string message) { error = message; });
    assert(received == 0 && error == "Something went wrong");
}

/**
 * Whether an operation that has no value to return succeeded, and the error when it did
 * not.
 *
 * The counterpart of Result for an operation that would otherwise return void. The error is
 * a message by default, written `OperationResult!()`.
 */
class OperationResult(E = string)
{
    private bool success;
    private E _error;

    private this(bool success, E error)
    {
        this.success = success;
        this._error = error;
    }

    /// Returns: Whether the operation succeeded.
    bool isSuccessful() const
    {
        return success;
    }

    /// Returns: Whether the operation failed.
    bool isFailure() const
    {
        return !success;
    }

    /// Returns: Why the operation failed. Only to be called on a failed result.
    E error()
    {
        assert(!success,
            "Result is successful so it does not have an error. Make sure to check isSuccessful() first.");
        return _error;
    }
}

/**
 * Creates a successful OperationResult.
 *
 * Params:
 *   E = The type of the error the operation would have had. A message when left out.
 *
 * Returns: A successful OperationResult.
 */
OperationResult!E success(E = string)()
{
    return new OperationResult!E(true, E.init);
}

/**
 * Creates a failed OperationResult.
 *
 * Params:
 *   E = The type of the error.
 *   error = Why the operation failed.
 *
 * Returns: A failed OperationResult with that error.
 */
OperationResult!E failure(E)(E error)
{
    return new OperationResult!E(false, error);
}

unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    enum Error
    {
        missing,
        broken
    }

    auto done = success();
    static assert(is(typeof(done) == OperationResult!()));
    assert(done.isSuccessful && !done.isFailure);
    assertThrown!AssertError(done.error);

    auto failed = failure("Something went wrong");
    assert(failed.isFailure && !failed.isSuccessful);
    assert(failed.error == "Something went wrong");

    static assert(is(typeof(success!Error()) == OperationResult!Error));

    auto broken = failure(Error.broken);
    static assert(is(typeof(broken) == OperationResult!Error));
    assert(broken.error == Error.broken);
}

/**
 * Calls onSuccess when the OperationResult is successful, and does nothing when it is a
 * failure.
 *
 * Params:
 *   E = The type of the result's error.
 *   Fn = The type of the callable action.
 *   res = The result to check.
 *   onSuccess = The action to call on success.
 */
void withResult(E, Fn)(OperationResult!E res, scope Fn onSuccess)
{
    if (res.isSuccessful)
    {
        onSuccess();
    }
}

/**
 * Calls onSuccess when the OperationResult is successful, or onError with its error when it
 * is a failure.
 *
 * Params:
 *   E = The type of the result's error.
 *   Fn = The type of the callable action.
 *   ErrFn = The type of the callable error action.
 *   res = The result to check.
 *   onSuccess = The action to call on success.
 *   onError = The action to call with the error on failure.
 */
void withResult(E, Fn, ErrFn)(OperationResult!E res, scope Fn onSuccess, scope ErrFn onError)
{
    if (res.isSuccessful)
    {
        onSuccess();
    }
    else
    {
        onError(res.error);
    }
}

unittest
{
    bool called;
    success().withResult(() { called = true; });
    assert(called);

    called = false;
    failure("Something went wrong").withResult(() { called = true; });
    assert(!called);

    string error;
    success().withResult(() { called = true; }, (string message) { error = message; });
    assert(called && error is null);

    called = false;
    failure("Something went wrong").withResult(() { called = true; }, (string message) { error = message; });
    assert(!called && error == "Something went wrong");
}
