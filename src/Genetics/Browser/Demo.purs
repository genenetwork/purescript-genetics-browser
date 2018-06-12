module Genetics.Browser.Demo where

import Prelude

import Color (Color, black)
import Color.Scheme.Clrs (blue, red)
import Color.Scheme.X11 (darkblue, darkgrey, lightgrey)
import Control.Monad.Aff (Aff, error, throwError)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log)
import Control.Monad.Except (runExcept)
import Data.Array as Array
import Data.BigInt (BigInt)
import Data.BigInt as BigInt
import Data.Either (Either(..))
import Data.Filterable (filter, filterMap, partition, partitionMap)
import Data.Foldable (class Foldable, fold, foldMap, foldr, length, minimumBy, sequence_)
import Data.FoldableWithIndex (foldMapWithIndex)
import Data.Foreign (F, Foreign, ForeignError(..))
import Data.Foreign (readArray) as Foreign
import Data.Foreign.Index (readProp) as Foreign
import Data.Foreign.Keys (keys) as Foreign
import Data.Function (on)
import Data.FunctorWithIndex (mapWithIndex)
import Data.Lens (re, view, (^.), (^?))
import Data.Lens.Index (ix)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Monoid (mempty)
import Data.Newtype (unwrap, wrap)
import Data.Pair (Pair(..))
import Data.Pair as Pair
import Data.Profunctor.Strong (fanout)
import Data.Record.Builder (build, insert, modify)
import Data.Record.Extra (class Keys)
import Data.Record.Extra (keys) as Record
import Data.Traversable (for)
import Data.Tuple (Tuple(Tuple))
import Data.Tuple as Tuple
import Data.Unfoldable (unfoldr)
import Data.Variant (inj)
import Genetics.Browser (DrawingN, DrawingV, Feature, LegendConfig, LegendEntry, NPoint, OldRenderer, Peak, RenderedTrack, VScale, chrLabelsUI, defaultLegendConfig, defaultVScaleConfig, drawLegendInSlot, drawVScaleInSlot, featureNormX, groupToMap, renderFixedUI, renderTrack, renderTrack', sigLevelRuler, trackLegend)
import Genetics.Browser.Bed (ParsedLine, fetchBed)
import Genetics.Browser.Canvas (BrowserCanvas, BrowserContainer, Label, LabelPlace(LLeft, LCenter), LayerRenderable, UISlotGravity(UIRight, UILeft), _Dimensions, _Track, _drawings, _labels, createAndAddLayer, getDimensions, uiSlots)
import Genetics.Browser.Coordinates (CoordSys, CoordSysView, Normalized(Normalized), _Segments, aroundPair, normalize, pairSize, pairsOverlap)
import Genetics.Browser.Layer (Component(Padded), Layer)
import Genetics.Browser.Types (Bp(Bp), ChrId(ChrId), NegLog10(..), _NegLog10)
import Graphics.Canvas as Canvas
import Graphics.Drawing (Drawing, Point, circle, fillColor, filled, lineWidth, outlineColor, outlined, rectangle)
import Graphics.Drawing as Drawing
import Graphics.Drawing.Font (font, sansSerif)
import Math as Math
import Network.HTTP.Affjax as Affjax
import Simple.JSON as Simple
import Type.Prelude (class RowToList, SProxy(SProxy))
import Unsafe.Coerce (unsafeCoerce)



type BedFeature = Feature { thickRange :: Pair Bp
                          , blocks :: Array (Pair Bp)
                          , geneId :: String
                          , geneName :: String
                          , chrId :: ChrId }


bedToFeature :: CoordSys ChrId BigInt -> ParsedLine -> Maybe BedFeature
bedToFeature cs pl = do
  seg@(Pair offset _ ) <- cs ^? _Segments <<< ix pl.chrom

  -- TODO validate ranges maybe, idk
  let toBp :: BigInt -> Bp
      toBp = wrap <<< BigInt.toNumber

      frameSize = toBp $ pairSize seg
      position = toBp  <$> Pair pl.chromStart pl.chromEnd
      thickRange = toBp  <$> Pair pl.thickStart pl.thickEnd

      blocks = Array.zipWith
                 (\start size -> map toBp (Pair start size))
                 pl.blockStarts pl.blockSizes

  pure { position
       , frameSize
       , feature: { thickRange
                  , blocks
                  , geneId: pl.geneId
                  , geneName: pl.geneName
                  , chrId: pl.chrom
                  }
       }


getGenes :: CoordSys ChrId BigInt
         -> String
         -> Aff _ (Map ChrId (Array BedFeature))
getGenes cs url = do
  ls <- fetchBed url

  let fs = filterMap (bedToFeature cs) ls

  pure $ groupToMap _.feature.chrId $ fs


bedDraw :: BedFeature
        -> DrawingV
bedDraw gene = inj (SProxy :: SProxy "range") \w ->
  let (Pair l r) = gene.position
      toLocal x = w * (unwrap $ x / gene.frameSize)

      width = toLocal (r - l)

      exon block =
        let p@(Pair exL' size') = toLocal <$> block
            s = rectangle exL' zero size' 30.0
        in (outlined (outlineColor darkgrey <> lineWidth 1.0) s)
        <> (filled (fillColor lightgrey) s)

      introns _ =
        let s = rectangle 1.5 14.0 (width-1.5) 2.0
        in outlined (outlineColor black <> lineWidth 3.0) s
        <> filled   (fillColor black) s

      label _ =
        Drawing.text
          (font sansSerif 12 mempty)
             (2.5) (35.0)
             (fillColor black) gene.feature.geneName

      drawing =
        if width < one
        then mempty
        else \_ -> introns unit
                <> foldMap exon gene.feature.blocks
                <> label unit

  in { drawing, width }

geneRenderer :: OldRenderer BedFeature
geneRenderer = inj (SProxy :: SProxy "single") { draw: bedDraw, horPlace, verPlace: const (Normalized 0.10) }
  where horPlace {position, frameSize} =
          let f p = Normalized (unwrap $ p / frameSize)
          in inj (SProxy :: SProxy "range") $ map f position



type SNPRow chr score r =
  ( "chrId"  :: chr
  , "name" :: String
  , "score" :: score
  | r )

type SNP r =
  Feature (Record (SNPRow ChrId Number r))

parseSNP :: CoordSys ChrId BigInt
         -> Foreign
         -> F (SNP ())
parseSNP cSys a = do
  raw <- Simple.read' a

  let
      snp :: { chr :: _, ps :: _, p_wald :: _, rs :: _ }
      snp = raw

      feature :: Record (SNPRow ChrId Number ())
      feature =
        { score:      snp.p_wald
        , chrId: wrap snp.chr
        , name:       snp.rs }

      position = (\p -> wrap <$> Pair p p) $ snp.ps

  frameSize <- case Map.lookup feature.chrId (view _Segments cSys) of

    Nothing ->
      throwError $ pure $ ForeignError
                     "Annotation chr not found in coordinate system!"
    Just seg ->
      pure $ Bp $ BigInt.toNumber $ pairSize seg

  pure $ { position
         , frameSize
         , feature }



type AnnotationRow chr pos r =
  ( "chr"  :: chr
  , "pos"  :: pos
  , "name" :: String
  , "url"  :: Maybe String
  , "gene" :: Maybe String
  | r )

type AnnotationField = { field :: String, value :: Foreign }

type Annotation r =
  Feature (Record (AnnotationRow ChrId Bp
                     ( rest :: List AnnotationField | r )))

annotationFields :: ∀ a b rl.
                    Keys rl
                 => RowToList (AnnotationRow a b ()) rl
                 => List String
annotationFields =
  Record.keys (unsafeCoerce unit :: Record (AnnotationRow a b ()))


parseAnnotation :: CoordSys ChrId BigInt
                -> Foreign
                -> F (Annotation ())
parseAnnotation cSys a = do
  raw <- Simple.read' a
  rest <- parseAnnotationRest a

  let
      feature =
        build
         (insert    (SProxy :: SProxy "rest") rest
         >>> modify (SProxy :: SProxy "chr") ChrId
         >>> modify (SProxy :: SProxy "pos") Bp) raw

      position = (\p -> Pair p p) $ feature.pos

  frameSize <- case Map.lookup feature.chr (view _Segments cSys) of


    Nothing ->
      throwError $ pure $ ForeignError
                     "Annotation chr not found in coordinate system!"
    Just seg ->
      pure $ Bp $ BigInt.toNumber $ pairSize seg

  pure $ { position
         , frameSize
         , feature }


-- | Partially parse the parts of the annotation record that are *not* in the Annotation type
parseAnnotationRest :: Foreign
                    -> F (List AnnotationField)
parseAnnotationRest a = do
  allFields <- List.fromFoldable <$> Foreign.keys a

  let restFields = allFields `List.difference` annotationFields

  for restFields \field ->
     { field, value: _ } <$> Foreign.readProp field a


-- | A completely dumb default way of rendering arbitrary annotation fields
showAnnotationField :: AnnotationField -> String
showAnnotationField fv = fv.field <> ": " <> unsafeCoerce fv.value


showAnnotation :: Annotation ()
               -> List String
showAnnotation a = (List.fromFoldable
                    [ name, chr, pos ]) <> (map showAnnotationField annot.rest)
  where annot = a.feature
        name = fromMaybe ("SNP: " <> annot.name)
                         (("Gene: " <> _) <$> annot.gene)
        chr = "Chr: " <> show annot.chr
        pos = "Pos: " <> show annot.pos


getSNPs :: CoordSys ChrId BigInt
        -> String
        -> Aff _ (Map ChrId (Array (SNP ())))
getSNPs cs url = do
  resp <- Affjax.get url

  rawSNPs <-
    case runExcept $ Foreign.readArray resp.response of
           Left err -> throwError $ error "SNP data is not an array"
           Right as -> pure as

  let parsed =
        partitionMap (runExcept <<< parseSNP cs) rawSNPs

  pure $ groupToMap _.feature.chrId
         $ filter (\f -> Pair.fst (f.position) >= wrap zero)
         $ parsed.right


getAnnotations :: CoordSys ChrId BigInt
               -> String
               -> Aff _ (Map ChrId (Array (Annotation ())))
getAnnotations cs url = do
  resp <- Affjax.get url

  rawAnnots <- case runExcept
                    $ Foreign.readArray resp.response of
                 Left err -> throwError $ error "Annotations data is not an array"
                 Right as -> pure as

  let parsed = partitionMap
               (runExcept <<< parseAnnotation cs) rawAnnots


  -- debug/testing stuff
  liftEff do
    log $ "Raw annotations array length: " <> show (Array.length rawAnnots)
    log $ "Could not parse "
        <> show (length parsed.left :: Int)
        <> " annotations."
    log $ "Successfully parsed "
        <> show (length parsed.right :: Int)
        <> " annotations."

    -- logging with unsafeCoerce lets us examine the raw JS object in the console!
    log $ unsafeCoerce (parsed.right)
  case Array.head parsed.right of
    Nothing -> pure unit
    Just an -> liftEff do
      log "first annotation: "
      sequence_ (log <$> (("> " <> _) <$> showAnnotation an))

  pure $ groupToMap _.feature.chr parsed.right



peak1 :: ∀ rS.
         Bp
      -> Array (SNP rS)
      -> Maybe (Tuple (Peak Bp Number (SNP rS))
                      (Array (SNP rS)))
peak1 radius snps = do
  top <- minimumBy (compare `on` _.feature.score) snps

  let covers = radius `aroundPair` top.position
      y = top.feature.score
      {no, yes} = partition (\p -> p.position `pairsOverlap` covers) snps

  pure $ Tuple {covers, y, elements: yes} no


peaks :: ∀ rS.
         Bp
      -> Array (SNP rS)
      -> Array (Peak Bp Number (SNP rS))
peaks r snps = unfoldr (peak1 r) snps

type DemoAnnotationConfig =
  { radius    :: Number
  , outline   :: Color
  , snpColor  :: Color
  , geneColor :: Color }

defaultDemoAnnotationConfig :: DemoAnnotationConfig
defaultDemoAnnotationConfig =
  { radius:    5.5
  , outline:   black
  , snpColor:  blue
  , geneColor: red }

annotationLegendEntry :: ∀ r. DemoAnnotationConfig -> Annotation r -> LegendEntry
annotationLegendEntry conf a =
  let mkIcon color = outlined (outlineColor conf.outline <> lineWidth 2.0)
                  <> filled (fillColor color)
                   $ circle 0.0 0.0 conf.radius
  in case a.feature.gene of
       Nothing -> { text: "SNP name",  icon: mkIcon conf.snpColor  }
       Just gn -> { text: "Gene name", icon: mkIcon conf.geneColor }


annotationLegendTest :: ∀ f r.
                   Foldable f
                => Functor f
                => DemoAnnotationConfig
                -> Map ChrId (f (Annotation r))
                -> Array LegendEntry
annotationLegendTest config fs = trackLegend (annotationLegendEntry config) as
  where as = Array.concat
             $ Array.fromFoldable
             $ Array.fromFoldable <$> Map.values fs



------------ new renderers~~~~~~~~~

placeScored :: ∀ r1 r2.
               { min :: Number, max :: Number | r1 }
            -> Feature { score :: Number | r2 }
            -> NPoint
placeScored vs s =
    { x: featureNormX s
    , y: wrap $ normYLogScore vs s.feature.score
    }


normYLogScore s =
  normalize s.min s.max <<< unwrap <<< view _NegLog10


dist :: Point -> Point -> Number
dist p1 p2 = Math.sqrt $ x' `Math.pow` 2.0 + y' `Math.pow` 2.0
  where x' = p1.x - p2.x
        y' = p1.y - p2.y


filterSig :: ∀ r1 r2.
             { sig :: Number | r1 }
          -> Map ChrId (Array (SNP r2))
          -> Map ChrId (Array (SNP r2))
filterSig {sig} = map (filter
  (\snp -> snp.feature.score <= (NegLog10 sig ^. re _NegLog10)))


snpsUI :: VScale
       -> UISlotGravity
       -> BrowserCanvas
       -> Drawing
snpsUI vscale = renderFixedUI (drawVScaleInSlot vscale)

annotationsUI :: ∀ r.
                 LegendConfig r
              -> UISlotGravity
              -> BrowserCanvas
              -> Drawing
annotationsUI legend = renderFixedUI (drawLegendInSlot legend)


type SNPConfig r
  = ( radius :: Number
    , color :: { outline :: Color
               , fill    :: Color }
    , pixelOffset :: Point
    | r )

defaultSNPConfig :: { | SNPConfig () }
defaultSNPConfig =
  { radius: 3.75
  , color: { outline: darkblue, fill: darkblue }
  , pixelOffset: {x: 0.0, y: 0.0}
  }



renderSNPs :: ∀ m r1 r2.
              { threshold  :: { min  :: Number, max :: Number | r1 }
              , snpsConfig :: { | SNPConfig () } | r2 }
           -> Canvas.Dimensions
           -> Map ChrId (Array (SNP ()))
           -> Map ChrId (Pair Number)
           -> RenderedTrack (SNP ())
renderSNPs { snpsConfig, threshold } cdim snpData =
  let features :: Array (SNP ())
      features = fold snpData

      snps = snpsConfig
      radius = snps.radius

      drawing =
          let {x,y} = snps.pixelOffset
              c     = circle x y radius
              out   = outlined (outlineColor snps.color.outline) c
              fill  = filled   (fillColor    snps.color.fill)    c
          in out <> fill

      drawings :: Array (Tuple (SNP ()) Point) -> Array DrawingN
      drawings pts = let (Tuple _ points) = Array.unzip pts
                     in [{ drawing, points }]

      npointed :: Map ChrId (Array (Tuple (SNP ()) NPoint))
      npointed = (map <<< map)
        (fanout id (\s ->
           { x: featureNormX s
           , y: wrap $ normYLogScore threshold s.feature.score })) snpData


      pointed :: Map ChrId (Pair Number)
              -> Array (Tuple (SNP ()) Point)
      pointed = foldMapWithIndex scaleSegs
        where rescale seg@(Pair offset _) npoint =
                  { x: offset + (pairSize seg) * (unwrap npoint.x)
                  , y: cdim.height * (one - unwrap npoint.y) }

              scaleSegs chrId seg = foldMap (map <<< map $ rescale seg)
                                      $ Map.lookup chrId npointed

      overlaps :: Array (Tuple (SNP ()) Point)
               -> Number -> Point
               -> Array (SNP ())
      overlaps pts radius' pt = filterMap covers pts
        where covers :: Tuple (SNP ()) Point -> Maybe (SNP ())
              covers (Tuple f fPt)
                | dist fPt pt <= radius + radius'   = Just f
                | otherwise = Nothing

  in \seg -> let pts = pointed seg
             in { features
                , drawings: drawings pts
                , labels: mempty
                , overlaps: overlaps pts }



renderSNPs' :: ∀ m r1 r2 r3.
              { threshold  :: { min  :: Number, max :: Number | r1 }
              , snpsConfig :: { | SNPConfig () } | r2 }
           -> Map ChrId (Array (SNP ()))
           -> Map ChrId (Pair Number)
           -> Canvas.Dimensions
           -> List LayerRenderable
renderSNPs' { snpsConfig, threshold } snpData =
  let features :: Array (SNP ())
      features = fold snpData

      snps = snpsConfig
      radius = snps.radius

      drawing =
          let {x,y} = snps.pixelOffset
              c     = circle x y radius
              out   = outlined (outlineColor snps.color.outline) c
              fill  = filled   (fillColor    snps.color.fill)    c
          in out <> fill

      drawings :: Array (Tuple (SNP ()) Point) -> Array DrawingN
      drawings pts = let (Tuple _ points) = Array.unzip pts
                     in [{ drawing, points }]

      npointed :: Map ChrId (Array (Tuple (SNP ()) NPoint))
      npointed = (map <<< map)
        (fanout id (\s ->
           { x: featureNormX s
           , y: wrap $ normYLogScore threshold s.feature.score })) snpData


      pointed :: _
              -> Map ChrId (Pair Number)
              -> Array (Tuple (SNP ()) Point)
      pointed size = foldMapWithIndex scaleSegs
        where rescale seg@(Pair offset _) npoint =
                  { x: offset + (pairSize seg) * (unwrap npoint.x)
                  , y: size.height * (one - unwrap npoint.y) }

              scaleSegs chrId seg = foldMap (map <<< map $ rescale seg)
                                      $ Map.lookup chrId npointed

      overlaps :: Array (Tuple (SNP ()) Point)
               -> Number -> Point
               -> Array (SNP ())
      overlaps pts radius' pt = filterMap covers pts
        where covers :: Tuple (SNP ()) Point -> Maybe (SNP ())
              covers (Tuple f fPt)
                | dist fPt pt <= radius + radius'   = Just f
                | otherwise = Nothing

  in \seg size ->
        let pts = pointed size seg
        in pure $ inj _drawings $ drawings pts
        -- in { features
        --    , drawings: drawings pts
        --    , labels: mempty
        --    , overlaps: overlaps pts }



annotationsForScale :: ∀ r1 r2 i c.
                       CoordSys i c
                    -> Map ChrId (Array (SNP r1))
                    -> Map ChrId (Array (Annotation r2))
                    -> Map ChrId (Pair Number)
                    -> Map ChrId (Array (Peak Bp Number (Annotation r2)))
annotationsForScale cSys snps annots =
  mapWithIndex \chr seg -> fromMaybe [] do
    segSnps      <- Map.lookup chr snps
    segAnnots    <- Map.lookup chr annots
    frameSize <- _.frameSize <$> Array.head segSnps

    let rad = (wrap 3.75 * frameSize) / (wrap $ pairSize seg)
        f pk = pk { elements = filter
                          (pairsOverlap pk.covers <<< _.position) segAnnots }

    pure $ f <$> peaks rad segSnps


renderAnnotationPeaks :: ∀ r r1 r2.
                         CoordSys ChrId BigInt
                      -> { min :: Number, max :: Number | r1 }
                      -> DemoAnnotationConfig
                      -> Map ChrId (Array (Peak Bp Number (Annotation r2)))
                      -> Canvas.Dimensions
                      -> Map ChrId (Pair Number)
                      -> { drawings :: _, labels :: _ }
renderAnnotationPeaks cSys vScale conf annoPks cdim =
  let

      curAnnotPeaks :: Map ChrId (Pair Number)
                    -> Map ChrId (Array (Peak Number Number (Annotation r2)))
      curAnnotPeaks segs = mapWithIndex f annoPks
        where f :: ChrId -> Array (Peak _ _ _) -> Array (Peak _ _ (Annotation r2))
              f chr pks = fromMaybe [] do
                  frameSize <- (wrap <<< BigInt.toNumber <<< pairSize)
                             <$> (Map.lookup chr $ cSys ^. _Segments)
                  pxSeg@(Pair l _) <- Map.lookup chr segs

                  let rescale pk = pk { covers = (\x -> l + pairSize pxSeg *
                                          (unwrap $ x / frameSize)) <$> pk.covers
                                      , y = cdim.height * (one - normYLogScore vScale pk.y) }

                  pure $ map rescale pks


      tailHeight = 0.06
      tailPixels = tailHeight * cdim.height
      iconYOffset = 6.5
      labelOffset = 8.0

      -- part of the canvas that a given peak will cover when rendered
      drawingCovers :: ∀ a.
                       Peak Number Number a
                    -> Canvas.Rectangle
      drawingCovers aPeak = {x,y,w,h}
        where (Pair x _) = aPeak.covers
              w = 14.0  -- hardcoded glyph width in pixels
              gH = (11.0 - iconYOffset) -- hardcoded height
              h = tailPixels + gH * length aPeak.elements
              y = aPeak.y - h


      drawAndLabel :: Peak Number Number (Annotation r2)
                   -> Tuple (Array DrawingN) (Array Label)
      drawAndLabel aPeak = Tuple [drawing] label
        where
              (Pair l r) = aPeak.covers
              x = l + 0.5 * (r - l)

              icons = Drawing.translate 0.0 (-tailPixels)
                      $ foldr (\a d -> Drawing.translate 0.0 (-iconYOffset)
                                     $ (annotationLegendEntry conf a).icon <> d)
                          mempty aPeak.elements

              tail = if Array.null aPeak.elements
                then mempty
                else Drawing.outlined (lineWidth 1.3 <> outlineColor black)
                       $ Drawing.path [ {x: 0.0, y: 0.0 }, {x: 0.0, y: -tailPixels }]

              drawing = { drawing: tail <> icons, points: [{x, y: aPeak.y }] }

              -- hardcoded font size because this will be handled by UI.Canvas later
              fontHeight = 14.0
              labelsHeight = length aPeak.elements * fontHeight

              dC = drawingCovers aPeak
                -- if all the labels fit above the icons, they're centered;
                -- otherwise just place them to the left and hope for the best
              {g, y0} = if dC.y > labelsHeight
                then { g: LCenter, y0: dC.y  }
                else { g: LLeft, y0: aPeak.y }

              label = Tuple.snd $ foldr f (Tuple y0 mempty) aPeak.elements
              f a (Tuple y ls) = Tuple (y - labelOffset)
                                    $ Array.snoc ls
                                         { text: fromMaybe a.feature.name a.feature.gene
                                         , point: { x, y }
                                         , gravity: g
                                         }


      drawAndLabelAll :: Map ChrId (Array (Peak _ _ _))
                      -> Tuple (Array DrawingN) (Array Label)
      drawAndLabelAll pks = foldMap (foldMap drawAndLabel) pks


  in \segs -> let (Tuple drawings labels) =
                    drawAndLabelAll $ curAnnotPeaks segs
              in { drawings, labels }


renderAnnotation' :: ∀ r r1 r2.
                    CoordSys _ _
                 -> Map ChrId (Array (SNP ()))
                 -> { threshold :: { min :: Number, max :: Number | r }
                    , annotationConfig :: DemoAnnotationConfig | r2 }
                 -> Map ChrId (Array (Annotation r2))
                 -> Map ChrId (Pair Number)
                 -> Canvas.Dimensions
                 -> List LayerRenderable
renderAnnotation' cSys sigSnps conf allAnnots =
  let features = fold allAnnots
      annoPeaks = annotationsForScale cSys sigSnps allAnnots


  in \seg size ->
        let {drawings, labels} =
              renderAnnotationPeaks cSys conf.threshold conf.annotationConfig (annoPeaks seg) size seg
        in List.fromFoldable
           [ inj _drawings $ drawings
           , inj _labels   $ labels ]


renderAnnotation :: ∀ r r1 r2.
                     CoordSys _ _
                  -> Map ChrId (Array (SNP ()))
                  -> { min :: Number, max :: Number | r }
                  -> DemoAnnotationConfig
                  -> Canvas.Dimensions
                  -> Map ChrId (Array (Annotation r2))
                  -> Map ChrId (Pair Number)
                  -> RenderedTrack (Annotation r2)
renderAnnotation cSys sigSnps vScale conf cdim allAnnots =
  let features = fold allAnnots
      annoPeaks = annotationsForScale cSys sigSnps allAnnots

  in \segs -> let {drawings, labels} =
                    renderAnnotationPeaks cSys vScale conf (annoPeaks segs) cdim segs
              in { features, overlaps: mempty
                 , drawings, labels }




demoBrowser :: ∀ r r2.
               CoordSys ChrId BigInt
            -> { score :: { min :: Number, max :: Number, sig :: Number } | r }
            -> { snps        :: Map ChrId (Array _)
               , annotations :: Map ChrId (Array _) | r2 }
            -> BrowserCanvas
            -> CoordSysView
            -> { tracks     :: { snps        :: RenderedTrack (SNP _)
                               , annotations :: RenderedTrack (Annotation _) }
               , relativeUI :: Drawing
               , fixedUI    :: Drawing }
demoBrowser cSys config trackData =
  let
      threshold = config.score
      vscale = defaultVScaleConfig threshold

      sigSnps = filterSig config.score trackData.snps
      legend = defaultLegendConfig
               $ (annotationLegendTest defaultDemoAnnotationConfig)
                  trackData.annotations

      conf = { segmentPadding: 12.0 }

      snps =
        renderTrack conf cSys (renderSNPs {threshold, snpsConfig: defaultSNPConfig}) trackData.snps

      annotations =
        renderTrack conf cSys (renderAnnotation cSys sigSnps vscale defaultDemoAnnotationConfig) trackData.annotations

      relativeUI = chrLabelsUI cSys {fontSize: 12}


  in \bc v ->
    let trackDim = bc ^. _Track <<< _Dimensions
        slots = uiSlots bc
        fixedUI =  (snpsUI        vscale UILeft  bc)
                <> (annotationsUI legend UIRight bc)
                <> (Drawing.translate slots.left.size.width slots.top.size.height
                    $ sigLevelRuler vscale red trackDim)

    in { tracks: { snps: snps bc v
                 , annotations: annotations bc v }
       , relativeUI: relativeUI bc v
       , fixedUI }



type BrowserConfig =
  { chrLabelsUI :: { fontSize :: Int }
  , legend :: DemoAnnotationConfig
  , threshold :: { min :: Number, max :: Number, sig :: Number }
  , snpsConfig :: { | SNPConfig () }
  }

addDemoLayers :: ∀ r r2.
                CoordSys ChrId BigInt
             -> { score :: { min :: Number, max :: Number, sig :: Number } | r }
             -> { snps        :: Map ChrId (Array (SNP ()))
                , annotations :: Map ChrId (Array (Annotation ())) | r2 }
             -> BrowserContainer
             -> Eff _ { snps        :: Number -> CoordSysView -> Eff _ Unit
                      , annotations :: Number -> CoordSysView -> Eff _ Unit }
addDemoLayers cSys config trackData =
  let threshold = config.score
      vscale = defaultVScaleConfig threshold

      sigSnps = filterSig config.score trackData.snps
      legend = defaultLegendConfig
               $ (annotationLegendTest defaultDemoAnnotationConfig)
                  trackData.annotations

      conf = { segmentPadding: 12.0 }

      snpLayer :: Layer (_ -> _ -> List LayerRenderable)
      snpLayer =
        renderTrack' conf cSys
          (Padded 5.0 $ renderSNPs' ) trackData.snps

      annotationLayer :: Layer (_ -> _ -> List LayerRenderable)
      annotationLayer =
        renderTrack' conf cSys
          (Padded 5.0 $ renderAnnotation' cSys sigSnps) trackData.annotations


  in \bc -> do
    dims <- getDimensions bc
    (Tuple _ renderSNPTrack)  <-
      createAndAddLayer bc "snps" snpLayer
    (Tuple _ renderAnnoTrack) <-
      createAndAddLayer bc "annotations" annotationLayer

    let snpsConfig = defaultSNPConfig
        annotationConfig = defaultDemoAnnotationConfig

    pure { snps: \o v ->
            renderSNPTrack  o { config: {threshold, snpsConfig}, view: v }
         , annotations: \o v ->
            renderAnnoTrack o { config: {threshold, annotationConfig}, view: v }
         }
