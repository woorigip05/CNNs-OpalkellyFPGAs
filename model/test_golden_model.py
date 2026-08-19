"""
Unit tests for the integer-only golden model (ABACUS-9), focused on
requantize() -- the piece with the most ways to get subtly wrong
(rounding, saturation, the two shift branches, ReLU fusion).

Run with: python3 -m unittest model.test_golden_model -v
      or: cd model && python3 -m unittest test_golden_model -v
"""

import unittest

import numpy as np

import golden_model as gm


def requantize_float_ref(acc, M0, shift, apply_relu=True, qmin=-128, qmax=127):
    """Independent float-domain reference for M = M0 * 2**(shift-31).

    Deliberately not sharing any code with requantize()'s integer path --
    the point is to catch bugs in the bit-shift arithmetic, not to agree
    with it by construction.
    """
    acc = np.asarray(acc, dtype=np.float64)
    m = np.float64(M0) * (2.0 ** (shift - 31))
    val = np.round(acc * m)
    lo = 0 if apply_relu else qmin
    return np.clip(val, lo, qmax).astype(np.int8)


class TestRequantize(unittest.TestCase):
    def test_zero_accumulator_is_zero(self):
        acc = np.array([0, 0, 0], dtype=np.int32)
        out = gm.requantize(acc, M0=1500000000, shift=-9)
        np.testing.assert_array_equal(out, [0, 0, 0])

    def test_relu_clips_negative_to_zero(self):
        acc = np.array([-1000, -1, 1000], dtype=np.int32)
        out = gm.requantize(acc, M0=1 << 30, shift=0, apply_relu=True)
        self.assertTrue((out[:2] == 0).all())

    def test_relu_disabled_allows_negative_down_to_qmin(self):
        # Real fc1 M0/shift map this accumulator to roughly -54 (not
        # saturated), letting us check the actual negative value survives
        # when ReLU isn't fused into the clamp.
        params = gm.load_params()
        acc = np.array([-40000], dtype=np.int32)
        out = gm.requantize(acc, params["fc1_M0"], params["fc1_shift"], apply_relu=False)
        self.assertLess(int(out[0]), 0)
        self.assertGreater(int(out[0]), -128)

    def test_saturates_at_qmax(self):
        acc = np.array([2**30], dtype=np.int32)
        out = gm.requantize(acc, M0=1 << 30, shift=30, apply_relu=True)
        self.assertEqual(int(out[0]), 127)

    def test_saturates_at_qmin_when_relu_disabled(self):
        acc = np.array([-(2**30)], dtype=np.int32)
        out = gm.requantize(acc, M0=1 << 30, shift=30, apply_relu=False)
        self.assertEqual(int(out[0]), -128)

    def test_output_dtype_is_int8(self):
        acc = np.array([12345, -6789], dtype=np.int32)
        out = gm.requantize(acc, M0=1495187284, shift=-9)
        self.assertEqual(out.dtype, np.int8)

    def test_matches_float_reference_positive_total_shift(self):
        # total_shift = 31 - shift > 0 is the branch every real per-layer
        # M0/shift pair from ABACUS-7 hits (fc1_shift=-9, fc2_shift=-8).
        rng = np.random.default_rng(0)
        acc = rng.integers(-(2**24), 2**24, size=2000, dtype=np.int64).astype(np.int32)
        M0, shift = 1495187284, -9
        got = gm.requantize(acc, M0, shift, apply_relu=False)
        want = requantize_float_ref(acc, M0, shift, apply_relu=False)
        np.testing.assert_array_equal(got, want)

    def test_matches_float_reference_with_relu(self):
        rng = np.random.default_rng(1)
        acc = rng.integers(-(2**24), 2**24, size=2000, dtype=np.int64).astype(np.int32)
        M0, shift = 2115194159, -8
        got = gm.requantize(acc, M0, shift, apply_relu=True)
        want = requantize_float_ref(acc, M0, shift, apply_relu=True)
        np.testing.assert_array_equal(got, want)

    def test_negative_total_shift_branch(self):
        # shift > 31 makes total_shift = 31 - shift negative, exercising
        # the left-shift-instead-of-round-shift branch. Not a case real
        # per-layer constants hit, but the code path exists and should
        # not silently do the wrong thing.
        acc = np.array([1], dtype=np.int32)
        out = gm.requantize(acc, M0=1, shift=40, apply_relu=True)
        # total_shift = 31 - 40 = -9 -> rescaled = 1 * 1 << 9 = 512, clipped to 127
        self.assertEqual(int(out[0]), 127)

    def test_real_fc1_constants_are_self_consistent(self):
        # Sanity check against the actual constants ABACUS-7 produced,
        # rather than only synthetic M0/shift pairs.
        params = gm.load_params()
        acc = np.array([-500000, 0, 500000], dtype=np.int32)
        got = gm.requantize(acc, params["fc1_M0"], params["fc1_shift"], apply_relu=True)
        want = requantize_float_ref(acc, params["fc1_M0"], params["fc1_shift"], apply_relu=True)
        np.testing.assert_array_equal(got, want)


class TestQuantizeInput(unittest.TestCase):
    def test_clips_to_int8_range(self):
        x = np.array([-100.0, 0.0, 100.0])
        out = gm.quantize_input(x, s_x=0.01)  # would be +/-10000 unclipped
        np.testing.assert_array_equal(out, [-128, 0, 127])

    def test_dtype_is_int8(self):
        out = gm.quantize_input(np.array([1.0]), s_x=1.0)
        self.assertEqual(out.dtype, np.int8)

    def test_rounds_to_nearest_step(self):
        out = gm.quantize_input(np.array([0.049, 0.051]), s_x=0.1)
        np.testing.assert_array_equal(out, [0, 1])


class TestLinearInt32(unittest.TestCase):
    def test_accumulates_wider_than_int8(self):
        # The exact overflow case documented in golden_model.py's module
        # docstring: int8 @ int8 wraps mod 256; int32 must not.
        x = np.array([[100, 100, 100]], dtype=np.int8)
        w = np.array([[100, 100, 100]], dtype=np.int8)
        b = np.array([0], dtype=np.int32)
        out = gm.linear_int32(x, w, b)
        self.assertEqual(out.dtype, np.int32)
        self.assertEqual(int(out[0, 0]), 30000)

    def test_adds_bias(self):
        x = np.array([[1, 1]], dtype=np.int8)
        w = np.array([[1, 1]], dtype=np.int8)
        b = np.array([42], dtype=np.int32)
        out = gm.linear_int32(x, w, b)
        self.assertEqual(int(out[0, 0]), 2 + 42)


class TestForwardIntegration(unittest.TestCase):
    def test_forward_shape_and_dtype_on_real_params(self):
        params = gm.load_params()
        x = np.zeros((5, 784), dtype=np.float32)
        logits = gm.forward(x, params)
        self.assertEqual(logits.shape, (5, 10))
        self.assertEqual(logits.dtype, np.int32)


if __name__ == "__main__":
    unittest.main()
