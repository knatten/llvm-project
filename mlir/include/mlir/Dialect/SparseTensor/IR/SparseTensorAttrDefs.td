//===-- SparseTensorAttrDefs.td - attributes definitions ---*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef SPARSETENSOR_ATTRDEFS
#define SPARSETENSOR_ATTRDEFS

include "mlir/IR/AttrTypeBase.td"
include "mlir/IR/EnumAttr.td"
include "mlir/IR/OpAsmInterface.td"
include "mlir/Dialect/SparseTensor/IR/SparseTensorBase.td"
include "mlir/IR/TensorEncoding.td"

// All of the sparse tensor attributes will extend this class.
class SparseTensor_Attr<string name,
                        list<Trait> traits = []>
    : AttrDef<SparseTensor_Dialect, name, traits>;

//===----------------------------------------------------------------------===//
// A simple bitset attribute wrapped around a single int64_t to encode a set of
// sparse tensor levels.
//===----------------------------------------------------------------------===//

def I64BitSetAttr : TypedAttrBase<I64, "IntegerAttr",
      And<[CPred<"::llvm::isa<::mlir::IntegerAttr>($_self)">,
           CPred<"::llvm::cast<::mlir::IntegerAttr>($_self).getType().isInteger(64)">]>,
      "LevelSet attribute"> {
  let returnType = [{::mlir::sparse_tensor::I64BitSet}];
  let convertFromStorage = [{::mlir::sparse_tensor::I64BitSet($_self.getValue().getZExtValue())}];
}

def I64BitSetArrayAttr :
    TypedArrayAttrBase<I64BitSetAttr, "I64BitSet array attribute">;

//===----------------------------------------------------------------------===//
// These attributes are just like `IndexAttr` except that they clarify whether
// the index refers to a dimension (an axis of the semantic tensor) or a level
// (an axis of the actual storage format).
//===----------------------------------------------------------------------===//

def DimensionAttr :
    TypedAttrBase<
      Index, "IntegerAttr",
      And<[CPred<"::llvm::isa<::mlir::IntegerAttr>($_self)">,
           CPred<"::llvm::isa<::mlir::IndexType>("
                     "::llvm::cast<::mlir::IntegerAttr>($_self).getType())">]>,
      "dimension attribute"> {
  let returnType = [{::mlir::sparse_tensor::Dimension}];
  let convertFromStorage = [{$_self.getValue().getZExtValue()}];
}

def LevelAttr :
    TypedAttrBase<
      Index, "IntegerAttr",
      And<[CPred<"::llvm::isa<::mlir::IntegerAttr>($_self)">,
           CPred<"::llvm::isa<::mlir::IndexType>("
                     "::llvm::cast<::mlir::IntegerAttr>($_self).getType())">]>,
      "level attribute"> {
  let returnType = [{::mlir::sparse_tensor::Level}];
  let convertFromStorage = [{$_self.getValue().getZExtValue()}];
}

//===----------------------------------------------------------------------===//
// Sparse Tensor Dimension Slice Attribute.
//===----------------------------------------------------------------------===//

def SparseTensorDimSliceAttr : SparseTensor_Attr<"SparseTensorDimSlice", []> {
  let mnemonic = "slice";

  let description = [{
    An attribute to encode slice information of a sparse tensor on a particular
    dimension (a tuple of offset, size, stride).
  }];

  let parameters = (
    ins
    "int64_t" : $offset,
    "int64_t" : $size,
    "int64_t" : $stride
  );

  let builders = [
    // The nop slice (i.e., that includes everything).
    AttrBuilder<(ins), [{ return $_get($_ctxt, 0, kDynamic, 1); }]>
  ];

  let extraClassDeclaration = [{
    void print(llvm::raw_ostream &os) const;

    /// Special value for dynamic offset/size/stride.
    static constexpr int64_t kDynamic = -1;
    static constexpr bool isDynamic(int64_t v) { return v == kDynamic; }
    static std::optional<uint64_t> getStatic(int64_t v);
    static std::string getStaticString(int64_t v);

    std::optional<uint64_t> getStaticOffset() const;
    std::optional<uint64_t> getStaticStride() const;
    std::optional<uint64_t> getStaticSize() const;
    bool isCompletelyDynamic() const;
  }];

  let genVerifyDecl = 1;
  let hasCustomAssemblyFormat = 1;
}

//===----------------------------------------------------------------------===//
// Sparse Tensor Type Encoding Attribute.
//===----------------------------------------------------------------------===//

// Sparse tensor encoding attribute.
def SparseTensorEncodingAttr : SparseTensor_Attr<"SparseTensorEncoding",
         [ DeclareAttrInterfaceMethods<VerifiableTensorEncoding>, OpAsmAttrInterface ] > {
  let mnemonic = "encoding";

  let description = [{
    An attribute to encode information on sparsity properties of tensors, inspired
    by the TACO formalization of sparse tensors. This encoding is eventually used
    by a **sparsifier** pass to generate sparse code fully automatically from a
    sparsity-agnostic representation of the computation, i.e., an implicit sparse
    representation is converted to an explicit sparse representation where co-iterating
    loops operate on sparse storage formats rather than tensors with a sparsity
    encoding. Compiler passes that run before this sparsifier pass need to be aware
    of the semantics of tensor types with such a sparsity encoding.

    In this encoding, we use **dimension** to refer to the axes of the semantic tensor,
    and **level** to refer to the axes of the actual storage format, i.e., the
    operational representation of the sparse tensor in memory. The number of
    dimensions is usually the same as the number of levels (such as CSR storage format).
    However, the encoding can also map dimensions to higher-order levels (for example,
    to encode a block-sparse BSR storage format) or to lower-order levels
    (for example, to linearize dimensions as a single level in the storage).

    The encoding contains a map that provides the following:

    - An ordered sequence of dimension specifications, each of which defines:
      - the dimension-size (implicit from the tensor’s dimension-shape)
      - a **dimension-expression**
    - An ordered sequence of level specifications, each of which includes a required
      **level-type**, which defines how the level should be stored. Each level-type
      consists of:
      - a **level-expression**, which defines what is stored
      - a **level-format**
      - a collection of **level-properties** that apply to the level-format

    Each level-expression is an affine expression over dimension-variables. Thus, the
    level-expressions collectively define an affine map from dimension-coordinates to
    level-coordinates. The dimension-expressions collectively define the inverse map,
    which only needs to be provided for elaborate cases where it cannot be inferred
    automatically.

    Each dimension could also have an optional `SparseTensorDimSliceAttr`.
    Within the sparse storage format, we refer to indices that are stored explicitly
    as **coordinates** and offsets into the storage format as **positions**.

    The supported level-formats are the following:

    - **dense** : all entries along this level are stored and linearized.
    - **batch** : all entries along this level are stored but not linearized.
    - **compressed** : only nonzeros along this level are stored
    - **loose_compressed** : as compressed, but allows for free space between regions
    - **singleton** : a variant of the compressed format, where coordinates have no siblings
    - **structured[n, m]** : the compression uses a n:m encoding
      (viz. n out of m consecutive elements are nonzero)

    For a compressed level, each position interval is represented in a compact
    way with a lowerbound `pos(i)` and an upperbound `pos(i+1) - 1`, which implies
    that successive intervals must appear in order without any "holes" in between
    them. The loose compressed format relaxes these constraints by representing each
    position interval with a lowerbound `lo(i)` and an upperbound `hi(i)`, which
    allows intervals to appear in arbitrary order and with elbow room between them.

    By default, each level-type has the property of being unique (no duplicate
    coordinates at that level) and ordered (coordinates appear sorted at that
    level). For singleton levels, the coordinates are fused with its parents in AoS
    (array of structures) scheme. The following properties can be added to a level-format
    to change this default behavior:

    - **nonunique** : duplicate coordinates may appear at the level
    - **nonordered** : coordinates may appear in arbribratry order
    - **soa** : only applicable to singleton levels, fuses the singleton
      level in SoA (structure of arrays) scheme.

    In addition to the map, the following fields are optional:

    - The required bitwidth for position storage (integral offsets
      into the sparse storage scheme).  A narrow width reduces the memory
      footprint of overhead storage, as long as the width suffices to
      define the total required range (viz. the maximum number of stored
      entries over all indirection levels).  The choices are `8`, `16`,
      `32`, `64`, or, the default, `0` to indicate the native bitwidth.

    - The required bitwidth for coordinate storage (the coordinates
      of stored entries).  A narrow width reduces the memory footprint
      of overhead storage, as long as the width suffices to define
      the total required range (viz. the maximum value of each tensor
      coordinate over all levels).  The choices are `8`, `16`, `32`,
      `64`, or, the default, `0` to indicate a native bitwidth.

    - The explicit value for the sparse tensor. If explicitVal is set,
      then all the non-zero values in the tensor have the same explicit value.
      The default value Attribute() indicates that it is not set. This
      is useful for binary-valued sparse tensors whose values can either
      be an implicit value (0 by default) or an explicit value (such as 1).
      In this approach, we don't store explicit/implicit values, and metadata
      (such as position and coordinate arrays) alone fully defines the original tensor.
      This yields additional savings for the storage requirements,
      as well as for the computational time, since we skip operating on
      implicit values and can constant fold the explicit values where they are used.

    - The implicit value for the sparse tensor. If implicitVal is set,
      then the "zero" value in the tensor is equal to the implicit value.
      For now, we only support `0` as the implicit value but it could be
      extended in the future. The default value Attribute() indicates that
      the implicit value is `0` (same type as the tensor element type).

    Examples:

    ```mlir
    // Sparse vector.
    #SparseVector = #sparse_tensor.encoding<{
      map = (i) -> (i : compressed)
    }>
    ... tensor<?xf32, #SparseVector> ...

    // Sorted coordinate scheme (arranged in AoS format by default).
    #SortedCOO = #sparse_tensor.encoding<{
      map = (i, j) -> (i : compressed(nonunique), j : singleton)
    }>
    // coordinates = {x_crd, y_crd}[nnz]
    ... tensor<?x?xf64, #SortedCOO> ...

    // Sorted coordinate scheme (arranged in SoA format).
    #SortedCOO = #sparse_tensor.encoding<{
      map = (i, j) -> (i : compressed(nonunique), j : singleton(soa))
    }>
    // coordinates = {x_crd[nnz], y_crd[nnz]}
    ... tensor<?x?xf64, #SortedCOO> ...

    // Batched sorted coordinate scheme, with high encoding.
    #BCOO = #sparse_tensor.encoding<{
      map = (i, j, k) -> (i : dense, j : compressed(nonunique, high), k : singleton)
    }>
    ... tensor<10x10xf32, #BCOO> ...

    // Compressed sparse row.
    #CSR = #sparse_tensor.encoding<{
      map = (i, j) -> (i : dense, j : compressed)
    }>
    ... tensor<100x100xbf16, #CSR> ...

    // Doubly compressed sparse column storage with specific bitwidths.
    #DCSC = #sparse_tensor.encoding<{
      map = (i, j) -> (j : compressed, i : compressed),
      posWidth = 32,
      crdWidth = 8
    }>
    ... tensor<8x8xf64, #DCSC> ...

    // Doubly compressed sparse column storage with specific
    // explicit and implicit values.
    #DCSC = #sparse_tensor.encoding<{
      map = (i, j) -> (j : compressed, i : compressed),
      explicitVal = 1 : i64,
      implicitVal = 0 : i64
    }>
    ... tensor<8x8xi64, #DCSC> ...

    // Block sparse row storage (2x3 blocks).
    #BSR = #sparse_tensor.encoding<{
      map = ( i, j ) ->
      ( i floordiv 2 : dense,
        j floordiv 3 : compressed,
        i mod 2      : dense,
        j mod 3      : dense
      )
    }>
    ... tensor<20x30xf32, #BSR> ...

    // Same block sparse row storage (2x3 blocks) but this time
    // also with a redundant reverse mapping, which can be inferred.
    #BSR_explicit = #sparse_tensor.encoding<{
      map = { ib, jb, ii, jj }
            ( i = ib * 2 + ii,
              j = jb * 3 + jj) ->
      ( ib = i floordiv 2 : dense,
        jb = j floordiv 3 : compressed,
        ii = i mod 2 : dense,
        jj = j mod 3 : dense)
    }>
    ... tensor<20x30xf32, #BSR_explicit> ...

    // ELL format.
    // In the simple format for matrix, one array stores values and another
    // array stores column indices. The arrays have the same number of rows
    // as the original matrix, but only have as many columns as
    // the maximum number of nonzeros on a row of the original matrix.
    // There are many variants for ELL such as jagged diagonal scheme.
    // To implement ELL, map provides a notion of "counting a
    // dimension", where every stored element with the same coordinate
    // is mapped to a new slice. For instance, ELL storage of a 2-d
    // tensor can be defined with the mapping (i, j) -> (#i, i, j)
    // using the notation of [Chou20]. Lacking the # symbol in MLIR's
    // affine mapping, we use a free symbol c to define such counting,
    // together with a constant that denotes the number of resulting
    // slices. For example, the mapping [c](i, j) -> (c * 3 * i, i, j)
    // with the level-types ["dense", "dense", "compressed"] denotes ELL
    // storage with three jagged diagonals that count the dimension i.
    #ELL = #sparse_tensor.encoding<{
      map = [c](i, j) -> (c * 3 * i : dense, i : dense, j : compressed)
    }>
    ... tensor<?x?xf64, #ELL> ...

    // CSR slice (offset = 0, size = 4, stride = 1 on the first dimension;
    // offset = 0, size = 8, and a dynamic stride on the second dimension).
    #CSR_SLICE = #sparse_tensor.encoding<{
      map = (i : #sparse_tensor<slice(0, 4, 1)>,
             j : #sparse_tensor<slice(0, 8, ?)>) ->
            (i : dense, j : compressed)
    }>
    ... tensor<?x?xf64, #CSR_SLICE> ...

    ```
  }];

  //
  // Data in sparse tensor encoding.
  //
  let parameters = (
    ins
    // A level-type for each level of the sparse storage
    // (consists of a level-format combined with level-properties).
    ArrayRefParameter<
      "::mlir::sparse_tensor::LevelType",
      "level-types"
      >: $lvlTypes,

    // A mapping from dimension-coordinates to level-coordinates.
    "AffineMap":$dimToLvl,

    // A mapping from level-coordinates to dimension-coordinates.
    "AffineMap":$lvlToDim,

    // The required bitwidth for position storage.
    "unsigned":$posWidth,

    // The required bitwidth for coordinate storage.
    "unsigned":$crdWidth,

    // The required explicit value.
    "::mlir::Attribute":$explicitVal,

    // The required implicit value.
    "::mlir::Attribute":$implicitVal,

    // A slice attribute for each dimension of the tensor type.
    ArrayRefParameter<
      "::mlir::sparse_tensor::SparseTensorDimSliceAttr",
      "per dimension slice metadata"
      >: $dimSlices
  );

  let builders = [
    AttrBuilder<(ins "ArrayRef<::mlir::sparse_tensor::LevelType>":$lvlTypes,
                     CArg<"AffineMap", "{}">:$dimToLvl,
                     CArg<"AffineMap", "{}">:$lvlToDim,
                     CArg<"unsigned", "0">:$posWidth,
                     CArg<"unsigned", "0">:$crdWidth,
                     CArg<"::mlir::Attribute", "{}">:$explicitVal,
                     CArg<"::mlir::Attribute", "{}">:$implicitVal), [{
      if (!dimToLvl) {
        dimToLvl = ::mlir::AffineMap::getMultiDimIdentityMap(lvlTypes.size(), $_ctxt);
      }
      if (!lvlToDim) {
        lvlToDim = ::mlir::sparse_tensor::inferLvlToDim(dimToLvl, $_ctxt);
      }
      return $_get($_ctxt, lvlTypes, dimToLvl, lvlToDim, posWidth, crdWidth,
        explicitVal, implicitVal,
        ArrayRef<::mlir::sparse_tensor::SparseTensorDimSliceAttr>{});
    }]>
  ];

  let extraClassDeclaration = [{
    //
    // Factory methods.
    //

    /// Constructs a new encoding with the given dimToLvl mapping,
    /// and all other fields inherited from `this`.
    SparseTensorEncodingAttr withDimToLvl(AffineMap dimToLvl) const;
    SparseTensorEncodingAttr withDimToLvl(SparseTensorEncodingAttr enc) const;

    /// Constructs a new encoding with dimToLvl reset to the default/identity,
    /// and all other fields inherited from `this`.
    SparseTensorEncodingAttr withoutDimToLvl() const;

    /// Constructs a new encoding with the given pointer and index
    /// bitwidths, and all other fields inherited from `this`.
    SparseTensorEncodingAttr withBitWidths(unsigned posWidth, unsigned crdWidth) const;

    /// Constructs a new encoding with the pointer and index bitwidths
    /// reset to the default, and all other fields inherited from `this`.
    SparseTensorEncodingAttr withoutBitWidths() const;

    /// Constructs a new encoding with the given explicit value
    /// and all other fields inherited from `this`.
    SparseTensorEncodingAttr withExplicitVal(Attribute explicitVal) const;

    /// Constructs a new encoding with the explicit value
    /// reset to the default, and all other fields inherited from `this`.
    SparseTensorEncodingAttr withoutExplicitVal() const;

    /// Constructs a new encoding with the given implicit value
    /// and all other fields inherited from `this`.
    SparseTensorEncodingAttr withImplicitVal(Attribute implicitVal) const;

    /// Constructs a new encoding with the implicit value
    /// reset to the default, and all other fields inherited from `this`.
    SparseTensorEncodingAttr withoutImplicitVal() const;

    /// Constructs a new encoding with the given dimSlices, and all
    /// other fields inherited from `this`.
    SparseTensorEncodingAttr withDimSlices(ArrayRef<::mlir::sparse_tensor::SparseTensorDimSliceAttr> dimSlices) const;

    /// Constructs a new encoding with the dimSlices reset to the default,
    /// and all other fields inherited from `this`.
    SparseTensorEncodingAttr withoutDimSlices() const;

    //
    // Rank methods.
    //

    /// Returns the expected number of tensor dimensions.  Asserts that
    /// the encoding is non-null (since no fixed result is valid for every
    /// dense-tensor).
    ::mlir::sparse_tensor::Dimension getDimRank() const;

    /// Returns the number of storage levels.  Asserts that the encoding
    /// is non-null (since no fixed result is valid for every dense-tensor).
    ::mlir::sparse_tensor::Level getLvlRank() const;

    uint64_t getBatchLvlRank() const;

    //
    // lvlTypes methods.
    //

    /// Safely looks up the level-type for the requested level.  (Returns
    /// `LevelType::Dense` for the null encoding, since dense-tensors
    /// are always all-dense.)
    ::mlir::sparse_tensor::LevelType getLvlType(::mlir::sparse_tensor::Level l) const;

    bool isDenseLvl(::mlir::sparse_tensor::Level l) const { return isDenseLT(getLvlType(l)); }
    bool isCompressedLvl(::mlir::sparse_tensor::Level l) const { return isCompressedLT(getLvlType(l)); }
    bool isSingletonLvl(::mlir::sparse_tensor::Level l) const { return isSingletonLT(getLvlType(l)); }
    bool isLooseCompressedLvl(::mlir::sparse_tensor::Level l) const { return isLooseCompressedLT(getLvlType(l)); }
    bool isNOutOfMLvl(::mlir::sparse_tensor::Level l) const { return isNOutOfMLT(getLvlType(l)); }
    bool isOrderedLvl(::mlir::sparse_tensor::Level l) const { return isOrderedLT(getLvlType(l)); }
    bool isUniqueLvl(::mlir::sparse_tensor::Level l) const { return isUniqueLT(getLvlType(l)); }

    /// Returns true if every level is dense.  Also returns true for
    /// the null encoding (since dense-tensors are always all-dense).
    bool isAllDense() const;

    /// Returns true if every level is ordered.  Also returns true for
    /// the null encoding (since dense-tensors are always all-ordered).
    bool isAllOrdered() const;

    //
    // Storage type methods.
    //

    /// Returns the coordinate-overhead MLIR type, defaulting to `IndexType`.
    Type getCrdElemType() const;

    /// Returns the position-overhead MLIR type, defaulting to `IndexType`.
    Type getPosElemType() const;

    /// Returns the coordinate-memref MLIR type, an optional tensorDimShape is
    /// used to refine the leading batch dimensions (if any).
    MemRefType getCrdMemRefType(
      std::optional<ArrayRef<int64_t>> tensorDimShape = std::nullopt) const;

    /// Returns the position-memref MLIR type, an optional tensorDimShape is
    /// used to refine the leading batch dimensions (if any).
    MemRefType getPosMemRefType(
      std::optional<ArrayRef<int64_t>> tensorDimShape = std::nullopt) const;

    //
    // dimToLvl methods.
    //

    /// Returns true if the dimToLvl mapping is the identity.
    /// Also returns true for the null encoding (since dense-tensors
    /// always have the identity mapping).
    bool isIdentity() const;

    /// Returns true if the dimToLvl mapping is a permutation.
    /// Also returns true for the null encoding (since dense-tensors
    /// always have the identity mapping).
    bool isPermutation() const;

    //
    // dimSlices methods.
    //

    bool isSlice() const;

    ::mlir::sparse_tensor::SparseTensorDimSliceAttr getDimSlice(::mlir::sparse_tensor::Dimension dim) const;

    std::optional<uint64_t> getStaticDimSliceOffset(::mlir::sparse_tensor::Dimension dim) const;
    std::optional<uint64_t> getStaticDimSliceStride(::mlir::sparse_tensor::Dimension dim) const;
    std::optional<uint64_t> getStaticLvlSliceOffset(::mlir::sparse_tensor::Level lvl) const;
    std::optional<uint64_t> getStaticLvlSliceStride(::mlir::sparse_tensor::Level lvl) const;

    //
    // Helper function to translate between level/dimension space.
    //

    SmallVector<int64_t> translateShape(::mlir::ArrayRef<int64_t> srcShape, ::mlir::sparse_tensor::CrdTransDirectionKind) const;
    ValueRange translateCrds(::mlir::OpBuilder &builder, ::mlir::Location loc, ::mlir::ValueRange crds, ::mlir::sparse_tensor::CrdTransDirectionKind) const;

    //
    // COO methods.
    //

    /// Returns the starting level of this sparse tensor type for a
    /// trailing COO region that spans **at least** two levels. If
    /// no such COO region is found, then returns the level-rank.
    ///
    /// DEPRECATED: use getCOOSegment instead;
    Level getAoSCOOStart() const;

    /// Returns a list of COO segments in the sparse tensor types.
    SmallVector<COOSegment> getCOOSegments() const;

    //
    // Printing methods.
    //

    void printSymbols(AffineMap &map, AsmPrinter &printer) const;
    void printDimensions(AffineMap &map, AsmPrinter &printer, ArrayRef<::mlir::sparse_tensor::SparseTensorDimSliceAttr> dimSlices) const;
    void printLevels(AffineMap &map, AsmPrinter &printer, ArrayRef<::mlir::sparse_tensor::LevelType> lvlTypes) const;

    //
    // OpAsmAttrInterface methods.
    //

    ::mlir::OpAsmAliasResult getAlias(::llvm::raw_ostream &os) const {
      os << "sparse";
      return ::mlir::OpAsmAliasResult::OverridableAlias;
    }
  }];

  let genVerifyDecl = 1;
  let hasCustomAssemblyFormat = 1;
}

//===----------------------------------------------------------------------===//
// Sparse Tensor Storage Specifier Enum Attribute.
//===----------------------------------------------------------------------===//

// The C++ enum for Storage Specifier kind.
def SparseTensorStorageSpecifierKindEnum
    : I32EnumAttr<"StorageSpecifierKind", "sparse tensor storage specifier kind", [
        I32EnumAttrCase<"LvlSize",    0, "lvl_sz">,
        I32EnumAttrCase<"PosMemSize", 1, "pos_mem_sz">,
        I32EnumAttrCase<"CrdMemSize", 2, "crd_mem_sz">,
        I32EnumAttrCase<"ValMemSize", 3, "val_mem_sz">,
        I32EnumAttrCase<"DimOffset",  4, "dim_offset">,
        I32EnumAttrCase<"DimStride",  5, "dim_stride">,
      ]> {
  let genSpecializedAttr = 0;
  let cppNamespace = SparseTensor_Dialect.cppNamespace;
}

// Define the enum StorageSpecifier kind attribute.
def SparseTensorStorageSpecifierKindAttr
    : EnumAttr<SparseTensor_Dialect, SparseTensorStorageSpecifierKindEnum,
               "SparseTensorStorageSpecifierKind"> {
   let mnemonic = "kind";
}

//===----------------------------------------------------------------------===//
// Sparse Tensor Traits.
//===----------------------------------------------------------------------===//

def IsSparseTensorPred
  : CPred<"!!::mlir::sparse_tensor::getSparseTensorEncoding($_self)">;

def IsSparseTensorSlicePred
  : CPred<"!!::mlir::sparse_tensor::getSparseTensorEncoding($_self) && "
          "  ::mlir::sparse_tensor::getSparseTensorEncoding($_self).isSlice()">;

class SparseTensorOf<list<Type> allowedTypes>
  : RankedTensorOf<allowedTypes, [IsSparseTensorPred], "sparse tensor">;

class SparseTensorSliceOf<list<Type> allowedTypes>
  : RankedTensorOf<allowedTypes, [IsSparseTensorSlicePred], "sparse tensor slice">;

class ScalarLikeOf<list<Type> allowedTypes>
  : AnyTypeOf<[0DTensorOf<allowedTypes>, AnyTypeOf<allowedTypes>], "scalar like">;

def AnySparseTensor : SparseTensorOf<[AnyType]>;
def AnySparseTensorSlice : SparseTensorSliceOf<[AnyType]>;
def AnyIndexingScalarLike : ScalarLikeOf<[AnySignlessIntegerOrIndex]>;

//===----------------------------------------------------------------------===//
// Sparse Tensor Sorting Algorithm Attribute.
//===----------------------------------------------------------------------===//

// Currently, we only provide four implementations, and expose the
// implementations via attribute algorithm. In the future, if we will
// need to support both stable and non-stable quick sort, we may add
// quick_sort_nonstable enum to the attribute. Alternative, we may use
// two attributes, (stable|nonstable, algorithm), to specify a sorting
// implementation.
//
// --------------------------------------------------------------------------
// |           | hybrid_qsort| insertion_sort | qsort       | heap_sort.    |
// |non-stable | Impl        | X              |  Impl       | Impl          |
// |stable     | X           | Impl           |  Not Impl   | X             |
// --------------------------------------------------------------------------

// The C++ enum for sparse tensor sort kind.
def SparseTensorSortKindEnum
    : I32EnumAttr<"SparseTensorSortKind", "sparse tensor sort algorithm", [
        I32EnumAttrCase<"HybridQuickSort",    0, "hybrid_quick_sort">,
        I32EnumAttrCase<"InsertionSortStable", 1, "insertion_sort_stable">,
        I32EnumAttrCase<"QuickSort", 2, "quick_sort">,
        I32EnumAttrCase<"HeapSort", 3, "heap_sort">,
      ]> {
  let genSpecializedAttr = 0;
  let cppNamespace = SparseTensor_Dialect.cppNamespace;
}

// Define the enum sparse tensor sort kind attribute.
def SparseTensorSortKindAttr
    : EnumAttr<SparseTensor_Dialect, SparseTensorSortKindEnum,
               "SparseTensorSortAlgorithm"> {
}


//===----------------------------------------------------------------------===//
// Sparse Tensor Coordinate Translation Direction Attribute.
//===----------------------------------------------------------------------===//

// The C++ enum for sparse tensor coordinate translation direction enum.
def SparseTensorCrdTransDirectionEnum
    : I32EnumAttr<"CrdTransDirectionKind", "sparse tensor coordinate translation direction", [
        I32EnumAttrCase<"dim2lvl", 0, "dim_to_lvl">,
        I32EnumAttrCase<"lvl2dim", 1, "lvl_to_dim">,
      ]> {
  let genSpecializedAttr = 0;
  let cppNamespace = SparseTensor_Dialect.cppNamespace;
}

// The C++ enum for sparse tensor coordinate translation direction attribute.
def SparseTensorCrdTransDirectionAttr
    : EnumAttr<SparseTensor_Dialect, SparseTensorCrdTransDirectionEnum,
               "CrdTransDirection"> {
}

#endif // SPARSETENSOR_ATTRDEFS
